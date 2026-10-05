import Foundation

package enum Engine: String, Codable {
    case whisperKit
    case whistle
    case phonon
}

package struct TranscriptionModel: Codable {
    package let id: String
    let displayName: String
    package let engine: Engine
    /// Engine-specific identifier (e.g. "openai_whisper-base.en" for WhisperKit).
    let whisperKitID: String?
    /// Hugging Face artifact file for Whistle (e.g. `whistle.cact`).
    let cactArtifact: String?
    let sizeMB: Int
    let languages: [String]
    let recommended: Bool
}

struct ModelsManifest: Codable {
    let models: [TranscriptionModel]
}
