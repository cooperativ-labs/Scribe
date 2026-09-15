# Knowledgebase transcript export

Scribe exports `*.kb.json` as the schema-backed transcript envelope accepted by Knowledgebase's
`transcript` resource type (`kb.meeting-transcript/1`). Scribe's ordinary `*.json` remains its
lossless canonical revision; the Knowledgebase document is an interoperability projection.

## Field mapping

| Knowledgebase | Scribe | Notes |
| --- | --- | --- |
| `source.ref` | `source.checksum` | Content-stable, so repeated uploads are idempotent. A legacy transcript with an empty checksum falls back to `scribe:<transcript_id>`. |
| `source.recorded_at` | `created_at` | Scribe canonical v1 does not retain recording start. `pipeline.scribe.recorded_at_basis` is therefore `transcript_created_at` rather than silently claiming exact provenance. |
| `source.duration_ms` | `source.duration_ms` | Exact millisecond duration. |
| `speakers[].id` | `speakers[].id` | Stable within the transcript revision. |
| `speakers[].label` | `speakers[].label_snapshot` | Historical display label from the exported revision. |
| `turns[]` | `segments[]` | Exact start/end milliseconds, text, and optional word timings. |
| `pipeline.scribe` | revision and processing metadata | Preserves the Scribe transcript id, revision, status, source filename, engine revisions, and processing options in Knowledgebase's open pipeline object. |

Scribe speaker-library profile IDs are intentionally not emitted as `person_node_id`: they do not
belong to Knowledgebase's node ID namespace. An unassigned segment maps to the stable
`SCRIBE_UNKNOWN` speaker. The same placeholder is emitted for a no-speech transcript because the
current Knowledgebase schema requires at least one speaker even when `turns` is empty.

## Suggested Knowledgebase v2 adjustments

- Permit an empty `speakers` array when `turns` is empty. This represents a silent recording
  without inventing a participant, while the existing unknown-speaker rule still covers speech
  with unresolved diarization.
- Give source time explicit semantics, for example `recorded_at_basis: recording_start | imported_at | transcript_created_at`, or make `recorded_at` optional. Producers often know import or
  transcript time but cannot recover the source recording's start time.
- Document `pipeline` as an extension point with namespaced producer metadata. This allows a
  projection to retain revision/provenance details without adding producer-specific top-level
  fields.
