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
  private var drainStdout: FileHandle?
  private var drainStderr: FileHandle?

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
    var environment = ProcessInfo.processInfo.environment
    environment["FERMION_CACHE_DIR"] = cache.path

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let child = Process()
    child.executableURL = PhononSupport.locateFermion()
    child.arguments = ["serve", modelID, "--host", "127.0.0.1", "--port", "0"]
    if let key = PhononRuntime.apiKey, !key.isEmpty {
      child.arguments?.append(contentsOf: ["--api-key", key])
    }
    child.environment = environment
    child.standardOutput = stdoutPipe
    child.standardError = stderrPipe

    var stderrAccumulator = Data()
    var stdoutLineBuffer = ""
    var detectedPort: Int?

    try child.run()

    let startupTimeout = PhononConfiguration.defaultStartupTimeout
    let deadline = Date().addingTimeInterval(startupTimeout)

    while Date() < deadline {
      if !child.isRunning, detectedPort == nil {
        stderrAccumulator.append(stderrPipe.fileHandleForReading.availableData)
        PhononSupport.saveServeDiagnostics(stderrAccumulator)
        throw PhononError.weightsMissing(
          Self.serveFailedMessage(exit: child.terminationStatus, logHint: true))
      }

      let outChunk = stdoutPipe.fileHandleForReading.availableData
      if !outChunk.isEmpty, let text = String(data: outChunk, encoding: .utf8) {
        stdoutLineBuffer += text
        while let newline = stdoutLineBuffer.firstIndex(of: "\n") {
          let line = String(stdoutLineBuffer[..<newline])
          stdoutLineBuffer.removeSubrange(...newline)
          if detectedPort == nil, let port = PhononSupport.parseServePort(from: line) {
            detectedPort = port
          }
        }
      }

      let errChunk = stderrPipe.fileHandleForReading.availableData
      if !errChunk.isEmpty {
        stderrAccumulator.append(errChunk)
      }

      if let port = detectedPort {
        let urlString = "http://127.0.0.1:\(port)"
        let configuration = try PhononConfiguration(
          urlString: urlString, modelID: modelID, apiKey: PhononRuntime.apiKey)
        let adapter = PhononHTTPAdapter(configuration: configuration)
        do {
          try await adapter.checkHealth()
          Self.startDraining(
            stdout: stdoutPipe.fileHandleForReading,
            stderr: stderrPipe.fileHandleForReading,
            storeStdout: &drainStdout,
            storeStderr: &drainStderr
          )
          process = child
          baseURL = configuration.baseURL
          owned = true
          return configuration.baseURL
        } catch {
          // Model still loading; keep polling until deadline.
        }
      }

      try await Task.sleep(nanoseconds: 200_000_000)
    }

    stderrAccumulator.append(stderrPipe.fileHandleForReading.availableData)
    PhononSupport.saveServeDiagnostics(stderrAccumulator)
    child.terminate()
    throw PhononError.weightsMissing(
      "fermion serve did not become ready within \(Int(startupTimeout))s"
        + (stderrAccumulator.isEmpty ? "" : "; see ~/Library/Logs/parrot/fermion-serve-last.log")
    )
  }

  package func stop() async {
    drainStdout?.readabilityHandler = nil
    drainStderr?.readabilityHandler = nil
    drainStdout = nil
    drainStderr = nil

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

  private static func startDraining(
    stdout: FileHandle,
    stderr: FileHandle,
    storeStdout: inout FileHandle?,
    storeStderr: inout FileHandle?
  ) {
    let drain: (FileHandle) -> Void = { handle in
      handle.readabilityHandler = { h in
        let data = h.availableData
        if data.isEmpty { h.readabilityHandler = nil }
      }
    }
    drain(stdout)
    drain(stderr)
    storeStdout = stdout
    storeStderr = stderr
  }
}
