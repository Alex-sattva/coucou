"""voice-mochi zero-shot test: clone from a short ref clip, no training.

Usage:
  .venv/bin/python scripts/zeroshot.py wavs/0001.wav --text "Salut, c'est Mochi !"
  .venv/bin/python scripts/zeroshot.py wavs/0001.wav --text-file Mochi-phrases.txt --out test/

Needs mlx-audio (installed) + one TTS model download on first run (then offline).

Mochi-phrases.txt: one phrase per line, the ~30 UI lines Mochi will say most.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("ref", help="reference clip (5-30s, clean, single speaker)")
    ap.add_argument("--text", default="Salut, c'est Mochi ! Prêt à coder ?",
                    help="single sentence to synthesize")
    ap.add_argument("--text-file", help="file with one phrase per line")
    ap.add_argument("--out", default="test", help="output dir")
    ap.add_argument("--model", default="mlx-community/Chatterbox-tts-mlx",
                    help="mlx-audio TTS model id")
    ap.add_argument("--ref-text", default=None,
                    help="transcript of the ref clip (skips auto-STT; recommended)")
    ap.add_argument("--lang", default="fr", help="language code (fr for French)")
    args = ap.parse_args()

    here = Path(__file__).resolve().parent.parent
    cwd = Path.cwd().resolve()
    ref = Path(args.ref)
    if not ref.is_absolute():
        ref = (cwd / ref).resolve()
    if not ref.exists():
        print(f"ref clip not found: {ref}", file=sys.stderr)
        sys.exit(1)

    texts = [args.text]
    if args.text_file:
        tf = Path(args.text_file)
        if not tf.is_absolute():
            tf = (cwd / tf).resolve()
        texts = [l.strip() for l in tf.read_text(encoding="utf-8").splitlines() if l.strip()]
    if not texts:
        print("no texts to synthesize", file=sys.stderr)
        sys.exit(1)

    out_arg = Path(args.out)
    if out_arg.is_absolute():
        out_dir = out_arg
    elif len(out_arg.parts) == 1:
        out_dir = here / out_arg
    else:
        out_dir = cwd / out_arg
    out_dir.mkdir(parents=True, exist_ok=True)

    try:
        from mlx_audio.tts.generate import generate_audio  # type: ignore
    except Exception as e:
        print(f"mlx-audio TTS unavailable: {e}", file=sys.stderr)
        print("try: .venv/bin/pip install -U mlx-audio", file=sys.stderr)
        sys.exit(1)

    print(f"[zero-shot] model={args.model} (first run downloads, then offline)...", flush=True)
    print(f"[zero-shot] ref={ref} lang={args.lang} n={len(texts)} -> {out_dir}", flush=True)
    if not args.ref_text:
        print("[zero-shot] no --ref-text given: ref clip will be auto-transcribed "
              "(downloads whisper STT model once). Pass --ref-text to skip that.", flush=True)

    for i, text in enumerate(texts):
        dest = out_dir / f"mochi_{i:02d}.wav"
        print(f"[{i+1}/{len(texts)}] {text[:70]}", flush=True)
        try:
            generate_audio(
                text,
                model=args.model,
                ref_audio=str(ref),
                ref_text=args.ref_text,  # None -> auto-transcribe ref via STT model
                lang_code=args.lang,
                output_path=str(out_dir),
                file_prefix=f"mochi_{i:02d}",
                audio_format="wav",
                verbose=False,
            )
            # generate_audio writes <prefix>.wav but appends _000 on collisions
            # with a previous run; drop a stale dest first so each run is clean
            if dest.exists():
                dest.unlink()
            cands = sorted(out_dir.glob(f"mochi_{i:02d}_*.wav"))
            if cands:
                cands[0].rename(dest)
            print(f"  -> {dest}", flush=True)
        except Exception as e:
            print(f"  failed: {e}", file=sys.stderr)
            print("  hint: --model mlx-community/Kokoro-82M-bf16 has fixed voices (no cloning); "
                  "for cloning try --model mlx-community/Chatterbox-tts-mlx or "
                  "--model mlx-community/F5-TTS-mlx", file=sys.stderr)
            break
    print(f"[zero-shot] done -> {out_dir} (listen, then decide: ship zero-shot refs or fine-tune)")


if __name__ == "__main__":
    main()
