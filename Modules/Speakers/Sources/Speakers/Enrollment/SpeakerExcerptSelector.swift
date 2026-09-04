import Foundation

/// Filters candidate excerpts to confirmed, clean speech and gathers a
/// 20–60 second collection target across several excerpts.
public struct SpeakerExcerptSelector: Sendable {
    public let configuration: SpeakerEnrollmentConfiguration

    public init(configuration: SpeakerEnrollmentConfiguration = .init()) {
        self.configuration = configuration
    }

    public func select(from excerpts: [SpeakerEnrollmentExcerpt]) throws -> [SpeakerEnrollmentExcerpt] {
        let clean = excerpts.filter { excerpt in
            excerpt.isConfirmed
                && excerpt.isCleanIgnoringDuration
                && excerpt.duration >= configuration.minimumUtteranceDuration
        }
        guard !clean.isEmpty else { throw SpeakerEnrollmentError.noCleanExcerpts }
        guard clean.count >= configuration.minimumExcerptCount else {
            throw SpeakerEnrollmentError.insufficientExcerpts(
                selected: clean.count,
                required: configuration.minimumExcerptCount
            )
        }

        var selected: [SpeakerEnrollmentExcerpt] = []
        var total: TimeInterval = 0
        for excerpt in clean {
            if total >= configuration.targetMinimumUsableSpeech,
               selected.count >= configuration.minimumExcerptCount,
               total + excerpt.duration > configuration.targetMaximumUsableSpeech {
                break
            }
            if total + excerpt.duration > configuration.targetMaximumUsableSpeech,
               total >= configuration.targetMinimumUsableSpeech,
               selected.count >= configuration.minimumExcerptCount {
                break
            }
            selected.append(excerpt)
            total += excerpt.duration
            if total >= configuration.targetMaximumUsableSpeech,
               selected.count >= configuration.minimumExcerptCount {
                break
            }
        }

        guard selected.count >= configuration.minimumExcerptCount else {
            throw SpeakerEnrollmentError.insufficientExcerpts(
                selected: selected.count,
                required: configuration.minimumExcerptCount
            )
        }
        guard total >= configuration.targetMinimumUsableSpeech else {
            throw SpeakerEnrollmentError.insufficientUsableSpeech(
                seconds: total,
                required: configuration.targetMinimumUsableSpeech
            )
        }
        return selected
    }
}
