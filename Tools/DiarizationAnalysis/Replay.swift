import Foundation

// Built by replay.py with the production host sources, without the worker SDK.
@main
struct Replay {
    static func main() throws {
        let joinApostrophes = CommandLine.arguments.contains("--intraword-apostrophes")
        let sentenceTurns = CommandLine.arguments.contains("--sentence-turns")
        let args = CommandLine.arguments.filter { $0 != "--intraword-apostrophes" && $0 != "--sentence-turns" }
        let run = URL(fileURLWithPath: args[1])
        let prepared = try JSONSerialization.jsonObject(with: Data(contentsOf: run.appendingPathComponent("prepare.json"))) as! [String: Any]
        let canonical = try JSONSerialization.jsonObject(with: Data(contentsOf: run.appendingPathComponent("canonical-transcript.json"))) as! [String: Any]
        let source = canonical["source"] as! [String: Any]
        let mapping: AudioTimeMapping
        if let value = prepared["timeMapping"] {
            mapping = try JSONDecoder().decode(AudioTimeMapping.self, from: JSONSerialization.data(withJSONObject: value))
        } else {
            // Historical checkpoints retain the full, untrimmed source timeline.
            // Refuse this fallback when durations do not establish that contract.
            let duration = source["duration_ms"] as! Int
            let preparedDuration = prepared["sourceDurationSeconds"] as! Double
            precondition(abs(preparedDuration * 1000 - Double(duration)) < 1)
            mapping = AudioTimeMapping(sourceSampleRate: 48_000, workingSampleRate: 16_000)
        }
        let words: [RecognizedWord]
        if args[2] == "--saved-words" {
            let document = try JSONSerialization.jsonObject(with: Data(contentsOf: run.appendingPathComponent("words.json"))) as! [String: Any]
            words = (document["words"] as! [[String: Any]]).map { w in
                RecognizedWord(id: w["id"] as! String, text: w["text"] as! String,
                    startMs: w["startMs"] as? Int, endMs: w["endMs"] as? Int,
                    enclosingStartMs: w["enclosingStartMs"] as! Int, enclosingEndMs: w["enclosingEndMs"] as! Int)
            }
        } else {
            let transcript = try WorkerASRTranscriptCodec.decode(Data(contentsOf: URL(fileURLWithPath: args[2])))
            words = try TokenTimingReconciler(configuration: .init(joinIntrawordApostrophes: joinApostrophes)).reconcile(.init(workerTranscript: transcript,
                timeMapping: mapping, sourceDurationMs: source["duration_ms"] as! Int)).words
        }
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[3]))) as! [String: Any]
        let turns = (document["intervals"] as! [[String: Any]]).map { t in
            DiarizedSpeakerTurn(speakerID: t["speakerID"] as! String,
                startMs: Int(((t["startSeconds"] as! Double) * 1000).rounded()),
                endMs: Int(((t["endSeconds"] as! Double) * 1000).rounded()),
                qualityScore: (t["qualityScore"] as? NSNumber)?.doubleValue ?? 1)
        }
        let result = try SpeakerTurnBuilder().build(words: words, diarizedTurns: turns)
        let intervals = (document["intervals"] as! [[String: Any]]).map { t in
            AcousticSpeakerInterval(speakerID: t["speakerID"] as! String,
                startMs: Int(((t["startSeconds"] as! Double) * 1000).rounded()),
                endMs: Int(((t["endSeconds"] as! Double) * 1000).rounded()),
                overlapsAnotherSpeaker: t["overlapsAnotherSpeaker"] as? Bool ?? false,
                qualityScore: (t["qualityScore"] as? NSNumber)?.doubleValue)
        }
        let energy = args.count > 4 ? try JSONDecoder().decode(SourceEnergyTimeline.self, from: Data(contentsOf: URL(fileURLWithPath: args[4]))) : nil
        let minimumAgreement = args.count > 5 ? Double(args[5])! : 0.95
        precondition((0...1).contains(minimumAgreement))
        let prior = energy.flatMap { SourceEnergyPrior(timeline: $0, intervals: intervals, minimumAgreement: minimumAgreement) }
        let reconciled = UnknownFragmentReconciler().reconcile(
            segments: result.segments, speakers: result.speakers, intervals: intervals, sourceEnergyPrior: prior
        ).map { prior?.confidenceAdjusted($0) ?? $0 }
        let effectiveBySegment = Dictionary(uniqueKeysWithValues: reconciled.map { ($0.id, $0.effectiveSpeakerID) })
        let paragraphs = TranscriptParagraphGrouper(configuration: sentenceTurns ? .sentenceTurns : .init()).paragraphs(from: reconciled)
        let encoder = JSONEncoder()
        let segments = try JSONSerialization.jsonObject(with: encoder.encode(result.segments))
        let reconciledJSON = try JSONSerialization.jsonObject(with: encoder.encode(reconciled))
        let wordIDsBySegment = Dictionary(grouping: result.wordAssignments, by: \.segmentID).mapValues { $0.map(\.wordID) }
        func row(_ p: TranscriptParagraph) -> [String: Any] {
            ["word_count": p.words?.count ?? p.text.split(whereSeparator: \.isWhitespace).count,
             "words": (p.words ?? []).map { ["text": $0.text, "start_ms": $0.startMs, "end_ms": $0.endMs] },
             "word_ids": p.sourceSegmentIDs.flatMap { wordIDsBySegment[$0] ?? [] }, "source_segment_ids": p.sourceSegmentIDs,
             "start_ms": p.startMs, "end_ms": p.endMs]
        }
        var output: [String: Any] = ["words": words.map { w -> [String: Any] in
            ["id": w.id, "text": w.text, "startMs": w.startMs as Any? ?? NSNull(),
             "endMs": w.endMs as Any? ?? NSNull(), "enclosingStartMs": w.enclosingStartMs,
             "enclosingEndMs": w.enclosingEndMs]
        }, "reconciled_segments": reconciledJSON, "labels": result.wordAssignments.map { $0.speakerID as Any? ?? NSNull() }, "segments": segments,
            "effective_labels": result.wordAssignments.map { (effectiveBySegment[$0.segmentID] ?? nil) as Any? ?? NSNull() },
            "display_paragraphs": paragraphs.map(row),
            "display_asides": paragraphs.flatMap(\.asides).map {
                ["word_count": $0.words?.count ?? $0.text.split(whereSeparator: \.isWhitespace).count,
                 "words": ($0.words ?? []).map { ["text": $0.text, "start_ms": $0.startMs, "end_ms": $0.endMs] },
                 "source_segment_count": $0.sourceSegmentCount, "word_ids": $0.sourceSegmentIDs.flatMap { wordIDsBySegment[$0] ?? [] },
                 "source_segment_ids": $0.sourceSegmentIDs]
            } ]
        if let prior {
            output["source_energy_prior"] = ["speaker_id": prior.selection.speakerID,
                "agreement": prior.selection.agreement, "microphone_coverage": prior.selection.microphoneCoverage,
                "evidence_ms": prior.selection.evidenceMs]
        }
        if sentenceTurns {
            // Private evidence only. Keep the control's output byte-semantically
            // compatible with the immutable replay contract.
            output["display_attribution_ranges"] = try (paragraphs + paragraphs.flatMap(\.asides)).map { p in
                ["source_segment_ids": p.sourceSegmentIDs,
                 "ranges": try p.attributionRanges.map { range -> [String: Any] in
                     ["source": try JSONSerialization.jsonObject(with: encoder.encode(range.source)),
                      "word_start": range.wordRange?.lowerBound as Any? ?? NSNull(),
                      "word_end": range.wordRange?.upperBound as Any? ?? NSNull()]
                 }] as [String: Any]
            }
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]))
    }
}
