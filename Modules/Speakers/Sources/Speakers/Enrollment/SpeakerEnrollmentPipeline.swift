import Foundation

/// Verified-sample enrollment. Signatures are written only from confirmed
/// clean excerpts extracted with a compatible embedding stack.
public struct SpeakerEnrollmentPipeline: Sendable {
    public let configuration: SpeakerEnrollmentConfiguration

    public init(configuration: SpeakerEnrollmentConfiguration = .init()) {
        self.configuration = configuration
    }

    public func enroll(
        request: SpeakerEnrollmentRequest,
        into store: SpeakerProfileStore,
        using extractor: any SpeakerEmbeddingExtracting
    ) async throws -> SpeakerEnrollmentResult {
        switch request.confirmation {
        case .automaticMatch:
            throw SpeakerEnrollmentError.automaticMatchCannotUpdateSignatures
        case .unconfirmed:
            throw SpeakerEnrollmentError.unconfirmedExamples
        case .userConfirmedExcerpts:
            break
        }

        let selected = try SpeakerExcerptSelector(configuration: configuration).select(from: request.excerpts)
        var extracted: [(SpeakerEnrollmentExcerpt, ExtractedSpeakerEmbedding)] = []
        extracted.reserveCapacity(selected.count)
        for excerpt in selected {
            let embeddings = try await extractor.extract(
                SpeakerEmbeddingExtractionRequest(
                    excerptID: excerpt.excerptID,
                    audioFileURL: request.audioFileURL,
                    ranges: excerpt.timeRanges
                )
            )
            guard embeddings.count < 2 else {
                throw SpeakerEnrollmentError.extractorReturnedMultipleSpeakers(excerpt.excerptID)
            }
            guard let embedding = embeddings.first else {
                throw SpeakerEnrollmentError.extractorReturnedNoEmbedding(excerpt.excerptID)
            }
            if let expected = configuration.expectedFormat, embedding.format != expected {
                throw SpeakerEnrollmentError.incompatibleEmbeddingFormat(
                    "expected \(describe(expected)), got \(describe(embedding.format))"
                )
            }
            extracted.append((excerpt, embedding))
        }

        let format = extracted[0].1.format
        if try await store.currentEmbeddingModel() != format.model {
            _ = try await store.setCurrentEmbeddingModel(format.model)
        }

        let profileID: UUID
        switch request.target {
        case let .existingProfile(existingID):
            guard try await store.profile(id: existingID) != nil else {
                throw SpeakerProfileStoreError.profileNotFound(existingID)
            }
            profileID = existingID
        case let .newProfile(displayName):
            let created = try await store.createProfile(SpeakerProfileDraft(displayName: displayName))
            profileID = created.profileID
        }

        for (excerpt, embedding) in extracted {
            let draft = SpeakerSignatureDraft(
                embeddingVector: embedding.vector,
                embeddingModel: embedding.format.model,
                preprocessingVersion: embedding.format.preprocessingVersion,
                normalizationVersion: embedding.format.normalizationVersion,
                transformVersion: embedding.format.transformVersion,
                usableSpeechDuration: embedding.usableSpeechDuration,
                qualityIndicators: SpeakerSignatureQuality(
                    silenceExcluded: !excerpt.containsSilence,
                    overlapExcluded: !excerpt.containsOverlap,
                    clippingExcluded: !excerpt.containsClipping,
                    minimumUtteranceDurationMet: excerpt.duration >= configuration.minimumUtteranceDuration
                ),
                enrollmentSourceID: request.sourceID,
                selectedTimeRanges: excerpt.timeRanges,
                retainedClipURL: request.retainClips ? embedding.clipURL : nil,
                confirmedAt: Date()
            )
            _ = try await store.addSignature(profileID: profileID, draft: draft)
        }

        guard let profile = try await store.profile(id: profileID) else {
            throw SpeakerProfileStoreError.profileNotFound(profileID)
        }
        return SpeakerEnrollmentResult(
            origin: request.origin,
            profile: profile,
            selectedExcerpts: selected,
            usableSpeechDuration: selected.reduce(0) { $0 + $1.duration },
            libraryRevision: try await store.revision()
        )
    }

    private func describe(_ format: SpeakerEmbeddingFormat) -> String {
        "\(format.model.modelID)@\(format.model.revision)/\(format.preprocessingVersion)/\(format.normalizationVersion)/\(format.transformVersion)"
    }
}
