import Foundation

/// Loads weights before the first dictation; swapped live when the model changes.
package protocol ModelLoadingTranscriber: Transcriber {
    func warmUp(progress: (@Sendable (Double) -> Void)?) async throws
    func unload() async
}

extension WhisperKitTranscriber: ModelLoadingTranscriber {}

package enum TranscriberFactory {
    package static func make(model: TranscriptionModel) throws -> any ModelLoadingTranscriber {
        switch model.engine {
        case .whisperKit:
            return WhisperKitTranscriber(model: model)
        case .whistle:
            return WhistleTranscriber(model: model)
        case .phonon:
            return PhononTranscriber(model: model)
        }
    }

    package static func isCached(_ model: TranscriptionModel) -> Bool {
        switch model.engine {
        case .whisperKit:
            return WhisperKitTranscriber.isCached(model)
        case .whistle:
            return WhistleTranscriber.isCached(model)
        case .phonon:
            return PhononTranscriber.isCached(model)
        }
    }
}
