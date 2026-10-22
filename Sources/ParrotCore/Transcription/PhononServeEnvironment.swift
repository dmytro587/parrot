import Foundation

/// Environment for a Parrot-owned ``fermion serve`` child (Phonon-2 memory tuning).
package enum PhononServeEnvironment {
  /// Fermion default is ``tdt16,dense16`` (+~400 MB peak). Parrot keeps speed, drops ``dense16``.
  package static let defaultP2Fast = "tdt16"
  /// Matches Fermion's shipped fast path (~175 MB saved vs disabling the tower).
  package static let defaultPhononEnc = "q8"
  /// MLX free-cache cap in MiB; ``0`` leaves MLX defaults.
  package static let defaultMLXCacheLimitMB = 256
  /// Seconds between idle ``clear_cache`` sweeps in the fermion child; ``0`` disables.
  package static let defaultIdleSweepSeconds = 45

  /// Merges Parrot defaults into ``environment`` for the serve subprocess.
  package static func apply(to environment: inout [String: String]) throws {
    if environment["FERMION_P2_FAST"] == nil {
      environment["FERMION_P2_FAST"] = defaultP2Fast
    }
    if environment["PHONON_ENC"] == nil {
      environment["PHONON_ENC"] = defaultPhononEnc
    }
    if environment["PARROT_PHONON_MLX_CACHE_LIMIT_MB"] == nil {
      environment["PARROT_PHONON_MLX_CACHE_LIMIT_MB"] = String(defaultMLXCacheLimitMB)
    }
    if environment["PARROT_PHONON_IDLE_SWEEP_SEC"] == nil {
      environment["PARROT_PHONON_IDLE_SWEEP_SEC"] = String(defaultIdleSweepSeconds)
    }
    let bootDir = try installPythonBootPath()
    let existing = environment["PYTHONPATH"] ?? ""
    if existing.isEmpty {
      environment["PYTHONPATH"] = bootDir
    } else if !existing.split(separator: ":").contains(where: { $0 == bootDir }) {
      environment["PYTHONPATH"] = "\(bootDir):\(existing)"
    }
  }

  /// ``~/Library/Application Support/parrot/phonon/python_boot`` with ``.pth`` + boot module.
  package static func installPythonBootPath() throws -> String {
    let root = try Paths.prepareDirectory(
      Paths.appSupport.appendingPathComponent("phonon/python_boot", isDirectory: true)
    )
    let bootPy = root.appendingPathComponent("parrot_fermion_boot.py")
    let pth = root.appendingPathComponent("parrot_fermion_boot.pth")
    let source = try bootScriptSource()
    if try bootPyContentsDiffer(at: bootPy, source: source) {
      try source.write(to: bootPy, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: bootPy.path)
    }
    let pthLine = "import parrot_fermion_boot\n"
    if try bootPyContentsDiffer(at: pth, source: pthLine) {
      try pthLine.write(to: pth, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: pth.path)
    }
    return root.path
  }

  private static func bootPyContentsDiffer(at url: URL, source: String) throws -> Bool {
    guard let data = try? Data(contentsOf: url),
      let existing = String(data: data, encoding: .utf8)
    else { return true }
    return existing != source
  }

  /// ``packaging/parrot_fermion_boot.py`` from the app bundle or repo (must exist).
  private static func bootScriptSource() throws -> String {
    if let bundled = bundledBootScript() {
      return bundled
    }
    throw PhononError.weightsMissing(
      "missing parrot_fermion_boot.py (reinstall Parrot.app or run from a source tree)")
  }

  private static func bundledBootScript() -> String? {
    let candidates = [
      Bundle.main.resourceURL?.appendingPathComponent("parrot_fermion_boot.py"),
      Bundle.main.bundleURL.deletingLastPathComponent()
        .appendingPathComponent("packaging/parrot_fermion_boot.py"),
    ]
    for url in candidates.compactMap({ $0 }) {
      if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
        return text
      }
    }
    let devPath = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("packaging/parrot_fermion_boot.py")
    if let text = try? String(contentsOf: devPath, encoding: .utf8), !text.isEmpty {
      return text
    }
    return nil
  }

}
