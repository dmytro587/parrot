import Foundation

/// Installs the Fermion CLI and MLX stack for Phonon-2 (`pip install --user`).
package enum PhononDependencyInstaller {
  package static let pipPackages = [
    "fermion-research",
    "mlx",
    "mlx-audio",
    "mlx-lm",
    "soundfile",
    "scipy",
    "zstandard",
  ]

  /// Idempotent: no-op when `fermion` is already on disk.
  package static func installIfNeeded(progress: ((String) -> Void)? = nil) throws {
    if PhononSupport.isFermionAvailable {
      progress?("✓ fermion already installed")
      return
    }
    try install(progress: progress)
  }

  package static func install(progress: ((String) -> Void)? = nil) throws {
    guard let python = locatePython() else {
      throw PhononError.weightsMissing(
        """
        No Python 3.10+ found. Install python.org 3.12 or Homebrew python@3.12, then run:
          parrot models install-runtime
        macOS /usr/bin/python3 is often 3.9 and cannot install fermion-research.
        """
      )
    }
    progress?("→ using \(python.path)")
    progress?("→ pip install --user \(pipPackages.joined(separator: " "))")
    try runPip(python: python, progress: progress)
    guard PhononSupport.isFermionAvailable else {
      let localBin = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin").path
      throw PhononError.weightsMissing(
        "pip finished but `fermion` was not found. Add \(localBin) to PATH, open a new terminal, and run `parrot doctor`."
      )
    }
    progress?("✓ fermion ready at \(PhononSupport.locateFermion()!.path)")
  }

  /// Prefer newer interpreters; skip `/usr/bin/python3` when it is 3.9.
  package static func locatePython() -> URL? {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    var candidates = [
      "/opt/homebrew/bin/python3.13",
      "/opt/homebrew/bin/python3.12",
      "/opt/homebrew/bin/python3.11",
      "/usr/local/bin/python3.13",
      "/usr/local/bin/python3.12",
      "/usr/local/bin/python3.11",
      "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3",
      "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
      "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3",
      home.appendingPathComponent(".local/bin/python3.13").path,
      home.appendingPathComponent(".local/bin/python3.12").path,
      home.appendingPathComponent(".local/bin/python3.11").path,
    ]
    if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
      for dir in pathEnv.split(separator: ":") {
        let base = String(dir).trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { continue }
        for name in ["python3.13", "python3.12", "python3.11", "python3"] {
          candidates.append((base as NSString).appendingPathComponent(name))
        }
      }
    }
    candidates.append("/usr/bin/python3")

    var seen = Set<String>()
    for path in candidates where seen.insert(path).inserted {
      guard fm.isExecutableFile(atPath: path) else { continue }
      if pythonVersion(at: URL(fileURLWithPath: path)) >= (3, 10) {
        return URL(fileURLWithPath: path)
      }
    }
    return nil
  }

  package static func pythonVersion(at python: URL) -> (Int, Int) {
    let process = Process()
    process.executableURL = python
    process.arguments = [
      "-c",
      "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')",
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return (0, 0) }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return (0, 0) }
    let text =
      String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let parts = text.split(separator: ".")
    guard parts.count >= 2,
      let major = Int(parts[0]),
      let minor = Int(parts[1])
    else { return (0, 0) }
    return (major, minor)
  }

  private static func runPip(python: URL, progress: ((String) -> Void)?) throws {
    let process = Process()
    process.executableURL = python
    process.arguments = ["-m", "pip", "install", "--user"] + pipPackages
    var environment = ProcessInfo.processInfo.environment
    environment["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let output =
      String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if process.terminationStatus != 0 {
      let tail = output.split(whereSeparator: \.isNewline).suffix(8).joined(separator: "\n")
      throw PhononError.weightsMissing(
        "pip install failed (status \(process.terminationStatus)).\n\(tail)"
      )
    }
    if !output.isEmpty {
      for line in output.split(whereSeparator: \.isNewline).suffix(5) {
        progress?(String(line))
      }
    }
  }
}
