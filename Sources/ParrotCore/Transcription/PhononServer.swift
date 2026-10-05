import Foundation

/// Starts and stops a loopback `fermion serve` child while Parrot holds the model loaded.
///
/// There is a single shared instance. ``PhononRuntime`` overrides (external URL, API key) are
/// process-wide; unloading Phonon stops the one Parrot-owned serve child.
package actor PhononServer {
  package static let shared = PhononServer()

  /// Loopback URL for an already-running server (advanced). Nil uses a Parrot-owned subprocess.
  package static var externalServiceURL: String?

  private var process: Process?
  private var baseURL: URL?
  private var owned = false

  package func start(modelID: String) async throws -> URL {
    if let external = Self.externalServiceURL, !external.isEmpty {
      let configuration = try PhononConfiguration(
        urlString: external, modelID: modelID, apiKey: PhononRuntime.apiKey)
      let adapter = PhononHTTPAdapter(configuration: configuration)
      try await adapter.checkHealth()
      return configuration.baseURL
    }

    if let baseURL, process?.isRunning == true {
      return baseURL
    }
    await stop()

    guard PhononSupport.locateFermion() != nil else {
      throw PhononError.weightsMissing(Self.missingFermionMessage)
    }

    let cache = try PhononModelStore.cacheRoot()
    try Paths.prepareDirectory(Paths.logs)
    let serveLog = Paths.logs.appendingPathComponent("fermion-serve-live.log")
    FileManager.default.createFile(atPath: serveLog.path, contents: nil)
    let serveLogHandle = try FileHandle(forWritingTo: serveLog)
    try serveLogHandle.truncate(atOffset: 0)

    var environment = ProcessInfo.processInfo.environment
    environment["FERMION_CACHE_DIR"] = cache.path
    environment["PYTHONUNBUFFERED"] = "1"

    let child = Process()
    child.executableURL = PhononSupport.locateFermion()
    child.arguments = ["serve", modelID, "--host", "127.0.0.1", "--port", "0"]
    if let key = PhononRuntime.apiKey, !key.isEmpty {
      child.arguments?.append(contentsOf: ["--api-key", key])
    }
    child.environment = environment
    child.standardOutput = FileHandle.nullDevice
    child.standardError = serveLogHandle

    try child.run()

    let startupTimeout = PhononConfiguration.defaultStartupTimeout
    let deadline = Date().addingTimeInterval(startupTimeout)
    let loadStarted = Date()
    var lastProgressLog = Date.distantPast
    var lastPortLog = Date.distantPast
    Log.info("starting fermion serve for \(modelID)…")

    while Date() < deadline {
      let elapsed = Int(Date().timeIntervalSince(loadStarted))
      if Date().timeIntervalSince(lastProgressLog) >= 15 {
        Log.info("loading Phonon (~\(elapsed)s, MLX model; first start is often ~60s)…")
        lastProgressLog = Date()
      }

      if !child.isRunning {
        try? serveLogHandle.close()
        if let log = try? Data(contentsOf: serveLog) {
          PhononSupport.saveServeDiagnostics(log)
        }
        throw PhononError.weightsMissing(
          Self.serveFailedMessage(exit: child.terminationStatus, logHint: true))
      }

      guard let port = PhononSupport.discoverListeningPort(processID: child.processIdentifier)
      else {
        try await Task.sleep(nanoseconds: 500_000_000)
        continue
      }

      if Date().timeIntervalSince(lastPortLog) >= 15 {
        Log.info("phonon: fermion listening on 127.0.0.1:\(port), waiting for health…")
        lastPortLog = Date()
      }

      let urlString = "http://127.0.0.1:\(port)"
      let configuration = try PhononConfiguration(
        urlString: urlString, modelID: modelID, apiKey: PhononRuntime.apiKey)
      let adapter = PhononHTTPAdapter(configuration: configuration)
      do {
        try await adapter.checkHealth()
        try? serveLogHandle.close()
        process = child
        baseURL = configuration.baseURL
        owned = true
        Log.info("phonon: fermion ready on \(urlString)")
        return configuration.baseURL
      } catch {
        try await Task.sleep(nanoseconds: 500_000_000)
      }
    }

    try? serveLogHandle.close()
    if let log = try? Data(contentsOf: serveLog) {
      PhononSupport.saveServeDiagnostics(log)
    }
    child.terminate()
    throw PhononError.weightsMissing(
      "fermion serve did not become ready within \(Int(startupTimeout))s; see ~/Library/Logs/parrot/fermion-serve-last.log"
    )
  }

  package func stop() async {
    guard owned, let process else {
      baseURL = nil
      return
    }
    if process.isRunning {
      process.terminate()
      let deadline = Date().addingTimeInterval(5)
      while process.isRunning, Date() < deadline {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      if process.isRunning {
        process.interrupt()
      }
    }
    self.process = nil
    baseURL = nil
    owned = false
  }

  private static let missingFermionMessage = """
    Phonon needs the `fermion` command on PATH (Python 3.10+).
      python3.12 -m pip install --user fermion-research mlx mlx-audio mlx-lm soundfile scipy zstandard
    macOS `/usr/bin/python3` is often 3.9 and cannot install fermion-research.
    Weights live in \(Paths.appSupport.path); Parrot starts the server for you.
    """

  private static func serveFailedMessage(exit: Int32, logHint: Bool) -> String {
    var message = "fermion serve exited before becoming ready (status \(exit))"
    if logHint {
      message += "; see ~/Library/Logs/parrot/fermion-serve-last.log"
    }
    return message
  }
}
