# Offline dictation VAD asset

`silero-vad-unified-256ms-v6.2.1.mlmodelc` is the Core ML conversion of
Silero VAD distributed by FluidInference at
https://huggingface.co/FluidInference/silero-vad-coreml . The model card
identifies its license as MIT. The original Silero Team MIT notice is in
`Workers/TranscriptionWorker/Licenses/Silero-VAD.txt` and is copied into
release packages.

The staged `weights/weight.bin` SHA-256 is
`53ecc8b5081146140ab654c89109cf001f2183abddd7a2411c5081feeffff063`.
The asset is loaded from the worker's SwiftPM resource bundle by URL. No
FluidAudio model download or cache fallback is invoked at runtime.
