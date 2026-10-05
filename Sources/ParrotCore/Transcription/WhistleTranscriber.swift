import Foundation

/// On-device speech recognition via Cactus Whistle (Needle engine).
package actor WhistleTranscriber: ModelLoadingTranscriber {
  static let sampleRate = 16_000
  /// Whistle accepts at most 30 s of 16 kHz mono audio per call.
  static let maxSamples = sampleRate * 30

  package let modelID: String
  private let model: TranscriptionModel
  private var retired = false
  private var warmed = false

  package init(model: TranscriptionModel) {
    self.modelID = model.id
    self.model = model
  }

  package func warmUp(progress: (@Sendable (Double) -> Void)? = nil) async throws {
    if warmed || retired { return }
    guard let artifact = model.cactArtifact else { throw TranscriberError.missingEngineID }
    let dest = try Self.modelURL(artifact: artifact)
    if !Self.isCached(model) {
      Log.info("downloading \(model.id)...")
      try await Self.download(artifact: artifact, to: dest, progress: progress)
    } else {
      progress?(1)
    }
    try Task.checkCancellation()
    if retired { return }
    try await NeedleRuntime.shared.loadIfNeeded(at: dest)
    warmed = true
    Log.info("✓ \(model.id) ready")
  }

  package func unload() async {
    retired = true
    warmed = false
  }

  package func transcribe(_ audio: [Float], context: TranscriptionContext) async throws
    -> Transcript
  {
    if !warmed { try await warmUp() }
    guard !retired else { throw TranscriberError.notLoaded }

    let started = CFAbsoluteTimeGetCurrent()
    let input = WhisperTuning.standard.prepare(audio)
    let clipped = Array(input.prefix(Self.maxSamples))
    let language = Self.language(for: context, model: model)
    let keywords = Self.keywords(from: context)

    let result = try await NeedleRuntime.shared.transcribe(
      pcm: clipped,
      language: language,
      keywords: keywords
    )
    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let total = CFAbsoluteTimeGetCurrent() - started
    let ttft = (result.ttft_ms ?? 0) / 1000
    var timings = TranscriberTimings(
      audioSeconds: Double(clipped.count) / Double(Self.sampleRate),
      preprocessing: 0,
      languageDetection: 0,
      total: total
    )
    timings.decoder = max(0, total - ttft)
    timings.language = result.language ?? language
    return Transcript(text: text, timings: timings)
  }

  /// ISO 639-1 code for Needle, or nil to detect.
  static func language(for context: TranscriptionContext, model: TranscriptionModel) -> String? {
    let spoken =
      context.spokenLanguages.isEmpty ? SpokenLanguage.preferredCodes() : context.spokenLanguages
    switch SpokenLanguage.plan(setting: context.language, spoken: spoken, model: model) {
    case .none:
      return nil
    case .fixed(let code):
      return code
    case .detect:
      return nil
    }
  }

  /// Newline-separated phrases for keyword biasing.
  static func keywords(from context: TranscriptionContext) -> String? {
    let terms = context.vocabulary.filter { !$0.isEmpty }
    guard !terms.isEmpty else { return nil }
    return terms.joined(separator: "\n")
  }

  package static func isCached(_ model: TranscriptionModel) -> Bool {
    guard let artifact = model.cactArtifact else { return false }
    guard let url = try? modelURL(artifact: artifact) else { return false }
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = attrs[.size] as? UInt64
    else { return false }
    return size > 1_000_000
  }

  private static func modelURL(artifact: String) throws -> URL {
    let dir = try Paths.prepareDirectory(
      Paths.appSupport.appendingPathComponent("models/cactus", isDirectory: true)
    )
    return dir.appendingPathComponent(artifact)
  }

  private static let downloadBase = URL(
    string: "https://huggingface.co/Cactus-Compute/whistle/resolve/main/")!

  private static func download(
    artifact: String,
    to dest: URL,
    progress: (@Sendable (Double) -> Void)?
  ) async throws {
    let url = downloadBase.appendingPathComponent(artifact)
    let (temp, response) = try await URLSession.shared.download(from: url)
    defer { try? FileManager.default.removeItem(at: temp) }
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw TranscriberError.needle("download failed for \(artifact)")
    }
    progress?(1)
    let fm = FileManager.default
    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
    try fm.moveItem(at: temp, to: dest)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
  }
}
