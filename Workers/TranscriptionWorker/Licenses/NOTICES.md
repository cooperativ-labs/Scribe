# Third-party notices — transcription helper

The transcription worker links a pinned FluidAudio release and loads separately
staged ASR and diarization model assets. This directory holds the notices that
must ship with the application. They are committed so a fresh checkout has them
before any package or model download has run.

## FluidAudio 0.12.4

- Upstream: <https://github.com/FluidInference/FluidAudio>
- Pin: tag `0.12.4`, revision `9830ce835881c0d0d40f90aabfaae3a6da5bebfb`
- Licence: Apache License 2.0
- File: `FluidAudio.txt`

## Parakeet TDT 0.6B v3 (Core ML)

- Upstream: <https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml>
- Revision: `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`
- Licence: Creative Commons Attribution 4.0 International
- File: `Parakeet-CC-BY-4.0.txt`

These model files are user-installed data, not signed executable contents. The
notice still ships in the app bundle so every distribution includes the required
attribution.

## Offline diarization models

- Upstream: <https://huggingface.co/FluidInference/speaker-diarization-coreml>
- Revision: `1ed7a662fdc7109e36d822db793ee6eebdaf8594`
- Licence: CC-BY-4.0 for the converted Core ML assets; see the notice for
  upstream pyannote (MIT) and WeSpeaker terms
- File: `Diarization-Models.txt`
