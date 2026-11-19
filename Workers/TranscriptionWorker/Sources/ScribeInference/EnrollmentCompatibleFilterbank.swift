@preconcurrency import CoreML
import FluidAudio

/// Uses the original Community-1 filterbank centering for stored WeSpeaker enrollments.
///
/// FluidAudio 0.18.3 inspects its temporary audio arrays after the synchronous
/// FBANK prediction and re-centers the features if a frame contains only exact
/// zeros. It exposes no switch for this pass. Mark the scratch arrays only after
/// the model has consumed them so each 25 ms frame has a nonzero sample. This
/// preserves the staged model's output, including for internally padded windows.
final class EnrollmentCompatibleFilterbank: MLModel {
    private let model: MLModel
    private static let frameHopSamples = 160

    init(model: MLModel) {
        self.model = model
        super.init()
    }

    override var modelDescription: MLModelDescription { model.modelDescription }

    override func predictions(from inputBatch: any MLBatchProvider,
                              options: MLPredictionOptions) throws -> any MLBatchProvider {
        let output = try model.predictions(from: inputBatch, options: options)
        for index in 0..<inputBatch.count {
            guard let audio = inputBatch.features(at: index).featureValue(for: "audio")?.multiArrayValue,
                  audio.dataType == .float32, audio.strides.last?.intValue == 1,
                  audio.shape.last?.intValue == audio.count else {
                throw OfflineDiarizationError.processingFailed("Expected a contiguous mono Float32 filterbank window")
            }
            audio.withUnsafeMutableBufferPointer(ofType: Float.self) { samples, _ in
                for offset in stride(from: 0, to: samples.count, by: Self.frameHopSamples) where samples[offset] == 0 {
                    samples[offset] = .leastNormalMagnitude
                }
            }
        }
        return output
    }
}
