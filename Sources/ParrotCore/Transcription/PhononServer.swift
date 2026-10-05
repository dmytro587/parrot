import Darwin
import Foundation

/// Starts and stops a loopback `fermion serve phonon-2` child while Parrot holds the model loaded.
package actor PhononServer {
  package static let shared = PhononServer()

  private var process: Process?
  private var baseURL: URL?
  private var owned = false

  /// Loopback URL for an already-running server (advanced). Nil uses a Parrot-owned subprocess.
  package static var externalServiceURL: String?

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

    guard let fermion = Self.locateFermion() else {
      throw PhononError.weightsMissing(
        """
        Phonon needs the `fermion` command on PATH (Python 3.10+).
          python3.12 -m pip install --user fermion-research mlx mlx-audio mlx-lm soundfile scipy zstandard
        macOS `/usr/bin/python3` is often 3.9 and cannot install fermion-research.
        Weights live in \(Paths.appSupport.path); Parrot starts the server for you.
        """
      )
    }

    let port = try Self.findFreePort()
    let cache = try PhononModelStore.cacheRoot()
    var environment = ProcessInfo.processInfo.environment
    environment["FERMION_CACHE_DIR"] = cache.path

    let child = Process()
    child.executableURL = fermion
    child.arguments = ["serve", modelID, "--host", "127.0.0.1", "--port", String(port)]
    if let key = PhononRuntime.apiKey, !key.isEmpty {
      child.arguments?.append(contentsOf: ["--api-key", key])
    }
    child.environment = environment
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    try child.run()

    let urlString = "http://127.0.0.1:\(port)"
    let configuration = try PhononConfiguration(
      urlString: urlString, modelID: modelID, apiKey: PhononRuntime.apiKey)
    let adapter = PhononHTTPAdapter(configuration: configuration)

    let deadline = Date().addingTimeInterval(configuration.startupTimeout)
    while Date() < deadline {
      if !child.isRunning {
        throw PhononError.weightsMissing("fermion serve exited before becoming ready")
      }
      do {
        try await adapter.checkHealth()
        process = child
        baseURL = configuration.baseURL
        owned = true
        return configuration.baseURL
      } catch {
        try await Task.sleep(nanoseconds: 200_000_000)
      }
    }
    child.terminate()
    throw PhononError.weightsMissing(
      "fermion serve did not become ready on \(urlString) within \(Int(configuration.startupTimeout))s"
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

  private static func locateFermion() -> URL? {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    var candidates = [
      "/usr/local/bin/fermion",
      "/opt/homebrew/bin/fermion",
      home.appendingPathComponent(".local/bin/fermion").path,
      "/Library/Frameworks/Python.framework/Versions/3.12/bin/fermion",
      "/Library/Frameworks/Python.framework/Versions/3.11/bin/fermion",
      "/Library/Frameworks/Python.framework/Versions/3.13/bin/fermion",
    ]
    if let userPyBins = try? fm.contentsOfDirectory(
      at: home.appendingPathComponent("Library/Python"),
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) {
      for versionDir in userPyBins
      where (try? versionDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
        candidates.append(versionDir.appendingPathComponent("bin/fermion").path)
      }
    }
    let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for dir in pathEnv.split(separator: ":") {
      let path = String(dir).trimmingCharacters(in: .whitespaces)
      guard !path.isEmpty else { continue }
      candidates.append((path as NSString).appendingPathComponent("fermion"))
    }
    var seen = Set<String>()
    for path in candidates where seen.insert(path).inserted {
      if fm.isExecutableFile(atPath: path) {
        return URL(fileURLWithPath: path)
      }
    }
    return nil
  }

  private static func findFreePort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw PhononError.weightsMissing("could not allocate a TCP port") }
    defer { close(fd) }

    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")

    let bindResult = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else {
      throw PhononError.weightsMissing("could not bind a loopback port for fermion serve")
    }

    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &bound) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &length)
      }
    }
    guard nameResult == 0 else {
      throw PhononError.weightsMissing("could not read bound port for fermion serve")
    }
    return Int(CFSwapInt16BigToHost(bound.sin_port))
  }
}
