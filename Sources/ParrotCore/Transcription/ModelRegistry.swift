import Foundation

/// Built-in transcription model registry.
///
/// The model list lives directly in source rather than as a JSON resource so
/// the binary stays self-contained — no `Bundle.module` lookup, no per-target
/// resource bundle to ship alongside the executable.
package enum ModelRegistry {
    static let shared: [TranscriptionModel] = [
        TranscriptionModel(
            id: "whistle",
            displayName: "Whistle",
            engine: .whistle,
            whisperKitID: nil,
            cactArtifact: "whistle.cact",
            sizeMB: 17,
            languages: ["en", "de", "fr", "es", "it", "nl", "pl"],
            recommended: true
        ),
        TranscriptionModel(
            id: "whisper-base.en",
            displayName: "Whisper Base (English)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-base.en",
            cactArtifact: nil,
            sizeMB: 145,
            languages: ["en"],
            recommended: false
        ),
        TranscriptionModel(
            id: "whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-large-v3-v20240930_turbo",
            cactArtifact: nil,
            sizeMB: 1620,
            languages: ["multi"],
            recommended: false
        ),
        TranscriptionModel(
            id: "whisper-small.en",
            displayName: "Whisper Small (English)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-small.en",
            cactArtifact: nil,
            sizeMB: 488,
            languages: ["en"],
            recommended: false
        ),
        TranscriptionModel(
            id: "whisper-small",
            displayName: "Whisper Small",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-small",
            cactArtifact: nil,
            sizeMB: 490,
            languages: ["multi"],
            recommended: false
        ),
    ]

    package static func find(_ id: String) -> TranscriptionModel? {
        shared.first { $0.id == id }
    }

    package static func recommended() -> TranscriptionModel? {
        shared.first { $0.recommended } ?? shared.first
    }
}
