# Knowledgebase transcript export

Scribe exports `*.kb.json` as the schema-backed file-upload envelope accepted by Knowledgebase's
transcript import UI (`kb.transcript-upload/1`). Scribe's ordinary `*.json` remains its lossless
canonical revision; the Knowledgebase document is an interoperability projection. The normative
contract is Knowledgebase's `docs/scribe-transcript-upload.schema.json`, with usage semantics in
`docs/TRANSCRIPT_INGEST.md`.

## Field mapping

| Knowledgebase upload | Scribe | Notes |
| --- | --- | --- |
| `recording.duration_ms` | `source.duration_ms` | Exact millisecond duration. |
| `recording.recorded_at` | omitted | Canonical transcript v1 does not retain recording start. Knowledgebase uses the meeting date when available rather than receiving a misleading transcript-creation time. |
| `transcript.processed_at` | `created_at` | Scribe writes the canonical revision when transcription finishes. |
| `transcript.language` | `language` | Language value retained from the canonical revision. |
| `segments[].speaker` | the referenced speaker's `label_snapshot` | A historical display label that Knowledgebase can match to saved people. Unassigned speech emits `null`. |
| `segments[].text`, `start_ms`, `end_ms` | `segments[]` | Exact segment text and source-relative millisecond range. The upload schema does not accept word-level timing. |
| `pipeline.producer.name` | `scribe` | Identifies the producer without claiming an unavailable app version. |
| `pipeline.extensions.ai.scribe` | revision and processing metadata | Preserves transcript ID, revision, status, source filename/checksum, timing/language provenance, engine revisions, and processing options in the contract's namespaced extension point. |

Scribe speaker-library profile IDs are intentionally not exported: they do not belong to
Knowledgebase's person-node namespace. Knowledgebase assigns canonical speaker IDs and optionally
matches speaker labels to people during import.

The upload schema requires at least one segment. A canonical no-speech transcript is therefore
represented as a speakerless `[silence]` segment spanning the recording duration. This uses the
contract's documented representation for non-speech without inventing a participant.
