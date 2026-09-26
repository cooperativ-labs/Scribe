import SwiftUI
@_exported import ScribeDesign

extension TranscriptDesign.SpeakerPalette {
    public init(speakers: [TranscriptSpeaker]) { self.init(speakerIDs: speakers.map(\.id)) }
}

// MARK: - View model palette

extension TranscriptViewModel {
    /// Colours for the selected recording's speakers, in speaker-table order.
    public var speakerPalette: TranscriptDesign.SpeakerPalette {
        TranscriptDesign.SpeakerPalette(speakers: recordingSpeakers)
    }

    public func speakerSwatch(forSpeakerID speakerID: String?) -> TranscriptDesign.SpeakerSwatch? {
        speakerPalette.swatch(forSpeakerID: speakerID)
    }

    /// nil means unknown: draw the dashed neutral dot.
    public func color(forSpeakerID speakerID: String?) -> Color? {
        speakerPalette.color(forSpeakerID: speakerID)
    }
}
