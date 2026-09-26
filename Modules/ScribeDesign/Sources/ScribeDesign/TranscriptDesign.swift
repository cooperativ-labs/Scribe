import SwiftUI

// MARK: - Glass rules
//
// The Transcripts window uses Liquid Glass sparingly, following the redesign
// proposal (mission coo:1072). The rules every later screen change follows:
//
// 1. Glass is for controls that float over content: the toolbar, the transport
//    capsule, toasts, the hover tool pill on a row, and the sidebar.
// 2. Content is flat: turn rows, chips, and sheets use plain tints on the
//    window background, never glass. Glass on glass loses the material of what
//    sits beneath it, which is the whole point of using it.
// 3. Tint only carries meaning. Orange marks something to check (an uncertain
//    or inferred speaker, estimated timing); red marks overlapping speech; the
//    accent marks what is playing or selected; a speaker colour marks who
//    spoke. Nothing else is coloured.
// 4. `glassEffect` needs macOS 26. On macOS 15 the same shapes are drawn in
//    `.regularMaterial` with a hairline and a soft shadow, which is the closest
//    thing the older system has, so both must look equivalent at a glance.
//
// Everything below is a token, a modifier, or a small reusable view. Screens
// are restyled in later objectives; this file only gives them a vocabulary.

/// Design tokens, type roles, colours, and surfaces for the Transcripts window.
public enum TranscriptDesign {

    // MARK: Spacing and radius

    public enum Spacing {
        /// Corner radius of a turn row's selection or playing background.
        public static let rowCornerRadius: CGFloat = 10
        public static let rowVerticalPadding: CGFloat = 8
        public static let rowHorizontalPadding: CGFloat = 12
        /// Width of the leading column that holds a turn's start time.
        public static let rowTimecodeColumnWidth: CGFloat = 52
        /// Width of the accent rail beside the playing row.
        public static let rowPlayingRailWidth: CGFloat = 3
        /// The longest comfortable line of turn text, in characters.
        public static let turnMeasureCharacters = 66

        public static let chipHorizontalPadding: CGFloat = 8
        public static let chipVerticalPadding: CGFloat = 4
        public static let chipSpacing: CGFloat = 6

        public static let transportHorizontalPadding: CGFloat = 16
        public static let transportVerticalPadding: CGFloat = 10
        /// Corner radius of the transport bar until it becomes a capsule.
        public static let transportCornerRadius: CGFloat = 14

        public static let hoverPillPadding: CGFloat = 4
        public static let hoverPillSpacing: CGFloat = 2

        /// Gap between the toast stack and the transport capsule it sits above.
        public static let toastGap: CGFloat = 12
        public static let toastSpacing: CGFloat = 8

        public static let flagDotDiameter: CGFloat = 7
        public static let speakerDotDiameter: CGFloat = 9
    }

    /// The outlines the window draws its surfaces in.
    public enum Surface {
        /// A turn row's selected or playing background.
        public static let row = Shape.rounded(Spacing.rowCornerRadius)
        public static let chip = Shape.capsule
        public static let transport = Shape.capsule
        public static let hoverPill = Shape.capsule
        public static let toast = Shape.capsule
        /// A generic panel, matching the transport bar before it became a capsule.
        public static let panel = Shape.rounded(Spacing.transportCornerRadius)
    }

    /// A shape choice that can be handed to both `glassEffect` and `background`.
    public enum Shape: Equatable, Sendable {
        case capsule
        case circle
        case rounded(CGFloat)

        public var anyShape: AnyShape {
            switch self {
            case .capsule: AnyShape(Capsule())
            case .circle: AnyShape(Circle())
            case let .rounded(radius): AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            }
        }
    }

    // MARK: Type roles

    public enum TypeRole {
        public static let turnFontSize: CGFloat = 14.5
        /// Line height as a multiple of the font size.
        public static let turnLineHeightMultiple: CGFloat = 1.55
        /// Body text of a turn.
        public static let turn = Font.system(size: turnFontSize)
        /// Extra space between lines that brings the system's natural line
        /// height (about 1.2×) up to `turnLineHeightMultiple`.
        public static let turnLineSpacing: CGFloat = (turnLineHeightMultiple - 1.2) * turnFontSize

        /// The speaker's name at the head of a turn or on a chip.
        #if os(iOS)
        public static let speakerName = Font.subheadline.weight(.semibold)
        #else
        public static let speakerName = Font.system(size: 13, weight: .semibold)
        #endif
        /// Start times and the transport readout; digits line up column to column.
        #if os(iOS)
        public static let timecode = Font.caption.monospacedDigit()
        public static let chip = Font.caption.weight(.medium)
        #else
        public static let timecode = Font.system(size: 12).monospacedDigit()
        public static let chip = Font.system(size: 12, weight: .medium)
        #endif
        /// The turn count on a speaker chip or the count badge on the filter menu.
        public static let badge = Font.system(size: 11, weight: .semibold).monospacedDigit()
    }

    // MARK: Semantic colours

    /// What a review flag on a turn says.
    public enum ReviewFlag: Equatable, Sendable, CaseIterable {
        /// Uncertain, inferred, or estimated: worth a look.
        case uncertain
        /// Two people at once: the words may belong to either.
        case overlap

        public var color: Color {
            switch self {
            case .uncertain: TranscriptDesign.reviewUncertain
            case .overlap: TranscriptDesign.reviewOverlap
            }
        }
    }

    public static let reviewUncertain = Color.orange
    public static let reviewOverlap = Color.red
    /// The one colour for what is playing or selected.
    public static let playing = Color.accentColor

    /// Flat tint strengths for content surfaces (rule 2).
    public enum Tint {
        /// Fill behind a chip in its meaning colour.
        public static let chipFill: Double = 0.14
        /// Fill behind a neutral chip.
        public static let neutralFill: Double = 0.06
        /// Background of the playing row.
        public static let playingRow: Double = 0.10
        /// Background of the selected row.
        public static let selectedRow: Double = 0.05
        public static let hairline: Double = 0.12
    }

    // MARK: Speaker palette

    /// One of the repeating speaker colours. The first four are the ones the
    /// proposal names; the rest keep a fifth speaker and beyond apart.
    public enum SpeakerSwatch: Int, CaseIterable, Equatable, Sendable {
        case blue
        case teal
        case orange
        case purple
        case pink
        case indigo
        case green
        case brown

        public var color: Color {
            switch self {
            case .blue: .blue
            case .teal: .teal
            case .orange: .orange
            case .purple: .purple
            case .pink: .pink
            case .indigo: .indigo
            case .green: .green
            case .brown: .brown
            }
        }

        /// The swatch for the speaker at `index` in recording-local order,
        /// wrapping round once the set is used up.
        public static func at(index: Int) -> SpeakerSwatch {
            let all = allCases
            return all[((index % all.count) + all.count) % all.count]
        }
    }

    /// Colours for one recording's speakers, fixed by the order they appear
    /// in the transcript's speaker table rather than by their labels, so a
    /// rename never changes a colour and reopening a file gives the same ones.
    public struct SpeakerPalette: Equatable, Sendable {
        private let indexByID: [String: Int]

        public static let empty = SpeakerPalette(speakerIDs: [])

        public init(speakerIDs: [String]) {
            var indexByID: [String: Int] = [:]
            for (index, id) in speakerIDs.enumerated() where indexByID[id] == nil {
                indexByID[id] = index
            }
            self.indexByID = indexByID
        }


        public var count: Int { indexByID.count }

        /// nil for a nil ID or a speaker the recording does not know, which the
        /// window renders as the dashed neutral dot.
        public func swatch(forSpeakerID speakerID: String?) -> SpeakerSwatch? {
            guard let speakerID, let index = indexByID[speakerID] else { return nil }
            return SpeakerSwatch.at(index: index)
        }

        public func color(forSpeakerID speakerID: String?) -> Color? {
            swatch(forSpeakerID: speakerID)?.color
        }
    }
}

// MARK: - Glass surfaces

/// Liquid Glass on systems that draw it, a material panel everywhere else.
///
/// Use it on controls only (rule 1). `interactive` lets the glass respond to
/// the pointer, which suits buttons and the transport but not a toast.
public struct TranscriptGlassSurface: ViewModifier {
    public let shape: TranscriptDesign.Shape
    public let interactive: Bool

    public init(shape: TranscriptDesign.Shape, interactive: Bool = false) {
        self.shape = shape
        self.interactive = interactive
    }

    public func body(content: Content) -> some View {
        if #available(iOS 26, macOS 26, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape.anyShape)
        } else {
            content
                .background(.regularMaterial, in: shape.anyShape)
                .overlay(shape.anyShape.stroke(.white.opacity(0.18), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        }
    }
}

extension View {
    /// Draws this view on a glass surface of the given shape.
    public func glassSurface(shape: TranscriptDesign.Shape, interactive: Bool = false) -> some View {
        modifier(TranscriptGlassSurface(shape: shape, interactive: interactive))
    }
}

/// Groups sibling glass surfaces so they blend as they approach each other.
///
/// On macOS 26 this is the system `GlassEffectContainer`; on macOS 15 it is
/// the content unchanged, since material panels have nothing to merge.
public struct TranscriptGlassEffectContainer<Content: View>: View {
    private let spacing: CGFloat?
    private let content: () -> Content

    public init(spacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    public var body: some View {
        if #available(iOS 26, macOS 26, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
}

// MARK: - Reusable views

/// A flat, capsule-shaped label for metadata (rule 2). A tint means something;
/// leave it nil for neutral facts such as length or language.
public struct TranscriptChip: View {
    public let title: String
    public let systemImage: String?
    public let tint: Color?

    public init(_ title: String, systemImage: String? = nil, tint: Color? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    public var body: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .font(TranscriptDesign.TypeRole.chip)
        .lineLimit(1)
        .padding(.horizontal, TranscriptDesign.Spacing.chipHorizontalPadding)
        .padding(.vertical, TranscriptDesign.Spacing.chipVerticalPadding)
        .foregroundStyle(tint ?? Color.secondary)
        .background(
            (tint ?? Color.primary).opacity(tint == nil ? TranscriptDesign.Tint.neutralFill : TranscriptDesign.Tint.chipFill),
            in: Capsule()
        )
    }
}

/// The dot after a speaker name that marks a turn as worth checking. The
/// caller supplies the wording through `.help` and the accessibility label.
public struct TranscriptFlagDot: View {
    public let flag: TranscriptDesign.ReviewFlag

    public init(_ flag: TranscriptDesign.ReviewFlag) {
        self.flag = flag
    }

    public var body: some View {
        Circle()
            .fill(flag.color)
            .frame(width: TranscriptDesign.Spacing.flagDotDiameter, height: TranscriptDesign.Spacing.flagDotDiameter)
            .accessibilityHidden(true)
    }
}

/// A speaker's colour as a dot. A speaker the recording does not know, or a
/// turn with no speaker, gets a dashed neutral ring instead of a colour.
public struct TranscriptSpeakerDot: View {
    public let swatch: TranscriptDesign.SpeakerSwatch?

    public init(_ swatch: TranscriptDesign.SpeakerSwatch?) {
        self.swatch = swatch
    }

    public var body: some View {
        Group {
            if let swatch {
                Circle().fill(swatch.color)
            } else {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: TranscriptDesign.Spacing.speakerDotDiameter, height: TranscriptDesign.Spacing.speakerDotDiameter)
        .accessibilityHidden(true)
    }
}

