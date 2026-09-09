# Transcript export Save panel (coo:982.hct2)

The Transcripts toolbar Export action used `fileImporter` with `.folder`, which presented an Open panel indistinguishable from Settings’ recordings-folder picker.

## What changed

Export now uses an NSSavePanel titled “Export Transcript” with prompt “Export”:

- TXT / JSON / SRT: save that document to a path and name the user chooses
- Export All: save TXT, JSON, and SRT copies beside each other using that name
- The recordings folder in Settings is not modified

The writer honors the chosen file URL (single format) or a custom basename (all formats).

## Tests

`swift test --package-path Modules/Transcription`: 242 tests, 0 failures. New coverage for writing to an exact Save-panel path, a chosen shared basename, and Save-panel URL parsing.
