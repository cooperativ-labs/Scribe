import Foundation

/// Checks that a cue list, and the document written from it, are a subtitle file a player accepts.
///
/// The exporter runs both passes on every export, so a malformed SRT is never written: the model
/// pass catches a builder mistake, and the document pass catches a rendering mistake.
public enum SubtitleCueValidator {
    /// Sequential numbering, positive duration, non-empty text, and chronological, non-overlapping
    /// display order.
    public static func validate(_ cues: [SubtitleCue]) throws {
        var previous: SubtitleCue?
        for (index, cue) in cues.enumerated() {
            guard cue.number == index + 1 else {
                throw Error.numberingNotSequential(expected: index + 1, found: String(cue.number))
            }
            guard cue.startMs >= 0 else { throw Error.negativeStart(number: cue.number, startMs: cue.startMs) }
            guard cue.endMs > cue.startMs else {
                throw Error.nonPositiveDuration(number: cue.number, startMs: cue.startMs, endMs: cue.endMs)
            }
            let lines = cue.lines
            guard !lines.isEmpty, !lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                throw Error.emptyText(number: cue.number)
            }
            if let previous { try checkOrder(previousNumber: previous.number, previousEndMs: previous.endMs, previousStartMs: previous.startMs, number: cue.number, startMs: cue.startMs) }
            previous = cue
        }
    }

    /// The same checks read back off the written document, including timestamp syntax.
    public static func validate(document: String) throws {
        let body = document.hasSuffix("\n") ? String(document.dropLast()) : document
        guard !body.isEmpty else { return }

        var previous: (number: Int, startMs: Int, endMs: Int)?
        for (index, block) in body.components(separatedBy: "\n\n").enumerated() {
            let lines = block.components(separatedBy: "\n")
            let expected = index + 1
            guard lines.count >= 3 else { throw Error.malformedCueBlock(number: expected) }
            guard lines[0] == String(expected) else {
                throw Error.numberingNotSequential(expected: expected, found: lines[0])
            }

            let bounds = lines[1].components(separatedBy: " --> ")
            guard bounds.count == 2,
                  let startMs = TranscriptTimecode.milliseconds(from: bounds[0], separator: .comma),
                  let endMs = TranscriptTimecode.milliseconds(from: bounds[1], separator: .comma) else {
                throw Error.malformedTimestampLine(number: expected, line: lines[1])
            }
            guard endMs > startMs else { throw Error.nonPositiveDuration(number: expected, startMs: startMs, endMs: endMs) }
            guard !lines[2...].contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                throw Error.emptyText(number: expected)
            }
            if let previous { try checkOrder(previousNumber: previous.number, previousEndMs: previous.endMs, previousStartMs: previous.startMs, number: expected, startMs: startMs) }
            previous = (expected, startMs, endMs)
        }
    }

    private static func checkOrder(previousNumber: Int, previousEndMs: Int, previousStartMs: Int, number: Int, startMs: Int) throws {
        guard startMs >= previousStartMs else { throw Error.outOfOrder(previousNumber: previousNumber, number: number) }
        guard startMs >= previousEndMs else { throw Error.displayOverlap(previousNumber: previousNumber, number: number) }
    }

    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case numberingNotSequential(expected: Int, found: String)
        case negativeStart(number: Int, startMs: Int)
        case nonPositiveDuration(number: Int, startMs: Int, endMs: Int)
        case emptyText(number: Int)
        case outOfOrder(previousNumber: Int, number: Int)
        case displayOverlap(previousNumber: Int, number: Int)
        case malformedCueBlock(number: Int)
        case malformedTimestampLine(number: Int, line: String)

        public var description: String {
            switch self {
            case .numberingNotSequential(let expected, let found):
                return "Cue numbering must run in sequence: expected \(expected) but found \(found)."
            case .negativeStart(let number, let startMs):
                return "Cue \(number) starts before the source at \(startMs) ms."
            case .nonPositiveDuration(let number, let startMs, let endMs):
                return "Cue \(number) has no positive duration: \(startMs) ms to \(endMs) ms."
            case .emptyText(let number):
                return "Cue \(number) has no text to display."
            case .outOfOrder(let previousNumber, let number):
                return "Cue \(number) starts before cue \(previousNumber)."
            case .displayOverlap(let previousNumber, let number):
                return "Cue \(number) is still on screen while cue \(previousNumber) is displayed."
            case .malformedCueBlock(let number):
                return "Cue \(number) is missing its number, timestamp, or text line."
            case .malformedTimestampLine(let number, let line):
                return "Cue \(number) has a malformed timestamp line: \(line)"
            }
        }
    }
}
