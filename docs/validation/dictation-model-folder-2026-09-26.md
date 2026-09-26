# Dictation model folder mismatch (2026-09-26)

Settings validates `ScribeSettings.modelsFolderURL`, but dictation previously
used `WorkerLocator.locate()` without supplying that folder. The worker then
defaulted to `models` under its working directory: `/models` when launched
from the installed application.

The app now supplies a required model-folder provider to `DictationEngine`.
Before warming or dictating, the engine resolves the current Settings folder
and passes it explicitly as `--models-directory`. A resident helper is reused
when the folder is unchanged and replaced when it changes. Concurrent warm
requests share the existing warm task.

Validation:

- The installed helper's `validate_assets` operation reports 35 missing files
  under `/models`, but reports `ready` with zero failures under
  `~/Library/Application Support/Scribe/Models`. No model download is needed.
- The installed helper also successfully completes the real dictation `warm`
  operation with that explicit folder while its working directory is `/`.
  This loads the ASR and bundled VAD models without microphone capture.
- All 16 Dictation package tests pass. The new process-based regression checks
  actual helper arguments for the default and custom folders, including spaces
  and Unicode, and checks helper reuse and replacement across folder changes.
- The full arm64 Release app build passes with `CODE_SIGNING_ALLOWED=NO`.
  This build has not replaced the installed app.
