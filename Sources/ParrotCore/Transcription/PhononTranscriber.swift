import Foundation

/// English speech recognition via Phonon-2: weights in Application Support, inference through
/// a Parrot-managed loopback `fermion serve` subprocess (MLX on Apple Silicon).
package actor PhononTranscriber: ModelLoadingTranscriber {
    package static let sampleRate = 16_000

    package let modelID: String
    private let model: TranscriptionModel
    private var adapter: PhononHTTPAdapter?
    private var retired = false
    private var warmed = false

    package init(model: TranscriptionModel) {
        self.modelID = model.id
        self.model = model
    }

    package func warmUp(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if warmed || retired { return }
        try await PhononModelStore.downloadIfNeeded { fraction in
            progress?(fraction * 0.9)
        }
        try Task.checkCancellation()
        if retired { return }

        let base = try await PhononServer.shared.start(modelID: model.id)
        let configuration = try PhononConfiguration(
            urlString: base.absoluteString,
            modelID: model.id,
            apiKey: PhononRuntime.apiKey
        )
        adapter = PhononHTTPAdapter(configuration: configuration)
        progress?(1)
        warmed = true
        Log.info("✓ \(model.id) ready")
    }

    package func unload() async {
        retired = true
        warmed = false
        adapter = nil
        await PhononServer.shared.stop()
    }

    package func transcribe(_ audio: [Float], context: TranscriptionContext) async throws
        -> Transcript
    {
        if !warmed { try await warmUp() }
        guard !retired, let adapter else { throw TranscriberError.notLoaded }

        let started = CFAbsoluteTimeGetCurrent()
        let input = WhisperTuning.standard.prepare(audio)
        let hotwords = Self.hotwords(from: context)
        let text = try await adapter.transcribe(
            samples: input,
            sampleRate: Double(Self.sampleRate),
            hotwords: hotwords
        )
        let total = CFAbsoluteTimeGetCurrent() - started
        let timings = TranscriberTimings(
            audioSeconds: Double(input.count) / Double(Self.sampleRate),
            preprocessing: 0,
            languageDetection: 0,
            total: total
        )
        return Transcript(text: text, timings: timings)
    }

    /// Comma-separated hotwords for Fermion (up to 25 terms).
    static func hotwords(from context: TranscriptionContext) -> String? {
        let terms = context.vocabulary.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return terms.prefix(25).joined(separator: ", ")
    }

    package static func isCached(_ model: TranscriptionModel) -> Bool {
        guard model.engine == .phonon else { return false }
        return PhononModelStore.isInstalled()
    }
}
