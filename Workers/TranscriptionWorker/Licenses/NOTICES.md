# Third-party notices — transcription helper

The transcription worker links a pinned FluidAudio release and loads separately
staged ASR and diarization model assets. This directory holds the notices that
must ship with the application. They are committed so a fresh checkout has them
before any package or model download has run.

## FluidAudio 0.18.3

- Upstream: <https://github.com/FluidInference/FluidAudio>
- Pin: tag `v0.18.3`, revision `c8b41f98eae668794dd0083bbe028fe7e6585051`
- Licence: Apache License 2.0
- File: `FluidAudio.txt`

## Parakeet TDT 0.6B v3 (Core ML)

- Upstream: <https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml>
- Revision: `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`
- Encoder: `Encoder_v2.mlmodelc`, per-channel int8 linear
- Licence: Creative Commons Attribution 4.0 International
- File: `Parakeet-CC-BY-4.0.txt`

These model files are user-installed data, not signed executable contents. The
notice still ships in the app bundle so every distribution includes the required
attribution.

## Community-1 offline diarization (Core ML)

- Upstream: <https://huggingface.co/FluidInference/speaker-diarization-coreml>
- Revision: `1ed7a662fdc7109e36d822db793ee6eebdaf8594`
- Licence: CC-BY-4.0 for the staged Community-1 artifacts. The notice credits
  pyannote, WeSpeaker, BUT Speech@FIT, and Fluid Inference.
- File: `Diarization-Models.txt`

## Parakeet CTC 110M (optional vocabulary boosting)

- Upstream: <https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml>
- Revision: `accdafd8cf8a2ff1cabe3c11e54416b405d409aa`
- Model card: Apache-2.0; repository metadata also labels CC-BY-4.0.
- Files: `Parakeet-CTC-110M.txt`, `Parakeet-CC-BY-4.0.txt`
