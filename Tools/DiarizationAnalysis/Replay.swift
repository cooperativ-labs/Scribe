import Foundation

// Built by replay.py with the production host sources, without the worker SDK.
@main
struct Replay {
    static func main() throws {
        let args = CommandLine.arguments
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
            words = try TokenTimingReconciler().reconcile(.init(workerTranscript: transcript,
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
        let reconciled = UnknownFragmentReconciler().reconcile(
            segments: result.segments, speakers: result.speakers,
            intervals: (document["intervals"] as! [[String: Any]]).map { t in
                AcousticSpeakerInterval(speakerID: t["speakerID"] as! String,
                    startMs: Int(((t["startSeconds"] as! Double) * 1000).rounded()),
                    endMs: Int(((t["endSeconds"] as! Double) * 1000).rounded()),
                    overlapsAnotherSpeaker: t["overlapsAnotherSpeaker"] as? Bool ?? false,
                    qualityScore: (t["qualityScore"] as? NSNumber)?.doubleValue)
            })
        let effectiveBySegment = Dictionary(uniqueKeysWithValues: reconciled.map { ($0.id, $0.effectiveSpeakerID) })
        let paragraphs = TranscriptParagraphGrouper().paragraphs(from: reconciled)
        let encoder = JSONEncoder()
        let segments = try JSONSerialization.jsonObject(with: encoder.encode(result.segments))
        let output: [String: Any] = ["words": words.map { w -> [String: Any] in
            ["id": w.id, "text": w.text, "startMs": w.startMs as Any? ?? NSNull(),
             "endMs": w.endMs as Any? ?? NSNull(), "enclosingStartMs": w.enclosingStartMs,
             "enclosingEndMs": w.enclosingEndMs]
        }, "labels": result.wordAssignments.map { $0.speakerID as Any? ?? NSNull() }, "segments": segments,
            "effective_labels": result.wordAssignments.map { (effectiveBySegment[$0.segmentID] ?? nil) as Any? ?? NSNull() },
            "display_paragraphs": paragraphs.map { ["word_count": $0.words?.count ?? $0.text.split(whereSeparator: \.isWhitespace).count] } ]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]))
    }
}
