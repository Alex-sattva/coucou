# voice-mochi — intake

Drop audio samples here. Raw recordings and consent stay local (gitignored).

## Where to put files

- `raw/` — original long recordings (wav/mp3/m4a, any quality)
- `wavs/` — cleaned 3–10s clips (I will generate these: 24kHz mono WAV)
- `metadata.csv` — `file,text` pairs (generated after transcription)
- `CONSENT.md` — written permission to clone + ship this voice in Coucou
  (who, what is allowed, commercial use yes/no, how to revoke, date + signature)

## Checklist before training

- [ ] Single speaker only, quiet room, no music
- [ ] 15 min minimum, 1–3h ideal
- [ ] Covers Mochi UI phrases + questions / exclamations / whispers
- [ ] FR + EN if Mochi speaks both
- [ ] CONSENT.md filled in

## What happens next

1. You drop files in `raw/`
2. I segment → denoise → normalize → transcribe (Whisper) → `wavs/` + `metadata.csv`
3. Zero-shot test (Chatterbox/F5 MLX, offline)
4. Fine-tune only if needed, export small MLX/ONNX for `NotchBuddy/`
