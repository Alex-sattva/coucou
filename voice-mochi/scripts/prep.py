"""voice-mochi prep: segment raw audio -> 24kHz mono 3-10s clips -> transcribe -> metadata.csv.

Usage:
  .venv/bin/python scripts/prep.py ../raw --out ../wavs
  .venv/bin/python scripts/prep.py ../raw/file.mp3 --out ../wavs

Steps per input file:
  1. Decode with bundled ffmpeg (imageio-ffmpeg, no system ffmpeg needed).
  2. Resample to 24kHz mono, normalize to -23 LUFS-ish (peak normalize 0.89).
  3. VAD-lite: split on silence (>=0.4s below -40dBFS), keep 3-10s chunks.
  4. Write wavs/XXXX.wav + transcribe with mlx-audio whisper -> metadata.csv

Transcription needs a whisper model download on first run (then offline).
Pass --no-transcribe to only segment.
"""
from __future__ import annotations

import argparse
import csv
import subprocess
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

try:
    import imageio_ffmpeg

    FFMPEG = imageio_ffmpeg.get_ffmpeg_exe()
except Exception:
    FFMPEG = "ffmpeg"

SR = 24000
MIN_LEN = 3.0
MAX_LEN = 10.0
SILENCE_THRESH_DB = -40.0
MIN_SILENCE_S = 0.4


def decode(path: Path, tmp: Path) -> tuple[np.ndarray, int]:
    tmp.write_bytes(b"")
    cmd = [
        FFMPEG, "-y", "-v", "error",
        "-i", str(path),
        "-ac", "1", "-ar", str(SR),
        "-f", "wav", str(tmp),
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"ffmpeg failed for {path.name}: {r.stderr[:500]}")
    audio, sr = sf.read(str(tmp), dtype="float32")
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    return audio, sr


def normalize(audio: np.ndarray) -> np.ndarray:
    peak = np.max(np.abs(audio)) + 1e-9
    audio = audio / peak * 0.89
    return audio.astype(np.float32)


def split_on_silence(audio: np.ndarray, sr: int) -> list[np.ndarray]:
    frame = int(0.02 * sr)  # 20ms frames
    n = len(audio) // frame
    if n == 0:
        return [audio] if len(audio) > 0 else []
    frames = audio[: n * frame].reshape(n, frame)
    rms = np.sqrt((frames**2).mean(axis=1) + 1e-12)
    db = 20 * np.log10(rms + 1e-12)
    silent = db < SILENCE_THRESH_DB
    # find silence runs >= MIN_SILENCE_S
    min_run = int(MIN_SILENCE_S / 0.02)
    cuts = [0]
    run = 0
    for i, s in enumerate(silent):
        if s:
            run += 1
        else:
            if run >= min_run:
                cuts.append(i - run // 2)
            run = 0
    cuts.append(n)
    chunks: list[np.ndarray] = []
    current = np.zeros(0, dtype=np.float32)
    for a, b in zip(cuts[:-1], cuts[1:]):
        seg = audio[a * frame : b * frame]
        if len(seg) < int(0.5 * sr):
            current = np.concatenate([current, seg])
            continue
        current = np.concatenate([current, seg]) if len(current) else seg
        # carve current into <= MAX_LEN pieces
        while len(current) > int(MAX_LEN * sr):
            chunks.append(current[: int(MAX_LEN * sr)])
            current = current[int(MAX_LEN * sr):]
        if len(current) >= int(MIN_LEN * sr):
            chunks.append(current)
            current = np.zeros(0, dtype=np.float32)
    if len(current) >= int(MIN_LEN * sr):
        chunks.append(current)
    return chunks


def transcribe(clips: list[Path]) -> dict[str, str]:
    try:
        from mlx_audio.stt import Model as STT  # type: ignore
    except Exception as e:
        print(f"[prep] mlx-audio STT unavailable ({e}); writing empty transcripts", file=sys.stderr)
        return {}
    print("[prep] loading whisper (first run downloads, then offline)...", flush=True)
    try:
        model = STT.from_pretrained("mlx-community/whisper-small-mlx")
    except Exception as e:
        print(f"[prep] whisper load failed: {e}", file=sys.stderr)
        return {}
    out: dict[str, str] = {}
    for clip in clips:
        try:
            text = model.generate(str(clip)) if hasattr(model, "generate") else model.transcribe(str(clip))
            if isinstance(text, dict):
                text = text.get("text", "")
            out[clip.name] = str(text).strip()
            print(f"  {clip.name}: {out[clip.name][:80]}", flush=True)
        except Exception as e:
            print(f"  {clip.name}: transcribe failed ({e})", file=sys.stderr)
            out[clip.name] = ""
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("inputs", nargs="+", help="raw file(s) or folder(s)")
    ap.add_argument("--out", default="wavs", help="output clips dir")
    ap.add_argument("--meta", default="metadata.csv", help="output csv")
    ap.add_argument("--no-transcribe", action="store_true")
    args = ap.parse_args()

    here = Path(__file__).resolve().parent.parent
    cwd = Path.cwd().resolve()
    out_arg = Path(args.out)
    # plain names ("wavs") default to the project dir next to this script;
    # anything with a separator respects CWD (so `voice-mochi/wavs` from root works)
    if out_arg.is_absolute():
        out_dir = out_arg
    elif len(out_arg.parts) == 1:
        out_dir = here / out_arg
    else:
        out_dir = cwd / out_arg
    out_dir.mkdir(parents=True, exist_ok=True)
    tmp = here / ".tmp_decode.wav"

    files: list[Path] = []
    for inp in args.inputs:
        p = Path(inp)
        if not p.is_absolute():
            p = (Path.cwd() / p).resolve()
        if p.is_dir():
            files += sorted(x for x in p.iterdir() if x.suffix.lower() in (".wav", ".mp3", ".m4a", ".ogg", ".flac", ".aac", ".opus", ".webm"))
        elif p.exists():
            files.append(p)
    if not files:
        print("no audio files found", file=sys.stderr)
        sys.exit(1)

    start_idx = len(list(out_dir.glob("*.wav")))
    clips: list[Path] = []
    for f in files:
        print(f"[prep] {f.name} ...", flush=True)
        try:
            audio, sr = decode(f, tmp)
        except Exception as e:
            print(f"  skip: {e}", file=sys.stderr)
            continue
        audio = normalize(audio)
        chunks = split_on_silence(audio, sr)
        print(f"  -> {len(chunks)} clips", flush=True)
        for ch in chunks:
            start_idx += 1
            name = f"{start_idx:04d}.wav"
            sf.write(str(out_dir / name), ch, SR)
            clips.append(out_dir / name)
    if tmp.exists():
        tmp.unlink()

    texts: dict[str, str] = {}
    if not args.no_transcribe and clips:
        texts = transcribe(clips)

    meta_arg = Path(args.meta)
    if meta_arg.is_absolute():
        meta_path = meta_arg
    elif len(meta_arg.parts) == 1:
        meta_path = here / meta_arg
    else:
        meta_path = cwd / meta_arg
    with open(meta_path, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["file", "text"])
        for c in sorted(clips):
            w.writerow([c.name, texts.get(c.name, "")])
    print(f"[prep] done: {len(clips)} clips -> {out_dir}, transcripts -> {meta_path}")
    print("[prep] NEXT: hand-fix metadata.csv (especially Mochi UI phrases), then zero-shot test.")


if __name__ == "__main__":
    main()
