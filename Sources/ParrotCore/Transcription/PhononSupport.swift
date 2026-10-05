import Foundation

/// Locating the Fermion CLI and writing serve diagnostics (never transcript text).
package enum PhononSupport {
    package static var isFermionAvailable: Bool { locateFermion() != nil }

    package static func locateFermion() -> URL? {
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
            where (try? versionDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            {
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

    /// Last `fermion serve` stderr when Parrot-owned startup failed (for support).
    package static func saveServeDiagnostics(_ data: Data) {
        guard !data.isEmpty else { return }
        do {
            try Paths.prepareDirectory(Paths.logs)
            let url = Paths.logs.appendingPathComponent("fermion-serve-last.log")
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.warning("could not write fermion-serve-last.log: \(error)")
        }
    }

    package static func parseServePort(from line: String) -> Int? {
        guard let host = line.range(of: "http://127.0.0.1:") else { return nil }
        let rest = line[host.upperBound...]
        let digits = rest.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }
}
