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
        parseLoopbackTCPPort(from: line)
    }

    /// Port from fermion log lines (`http://127.0.0.1:…`) or `lsof` (`127.0.0.1:…` / `localhost:…`).
    package static func parseLoopbackTCPPort(from line: String) -> Int? {
        for prefix in ["http://127.0.0.1:", "127.0.0.1:", "localhost:"] {
            guard let host = line.range(of: prefix) else { continue }
            let rest = line[host.upperBound...]
            let digits = rest.prefix(while: \.isNumber)
            if !digits.isEmpty, let port = Int(digits) { return port }
        }
        return nil
    }

    /// When fermion stderr is buffered, discover the loopback port from the child process.
    package static func discoverListeningPort(processID: Int32) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", String(processID), "-iTCP", "-sTCP:LISTEN"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output =
            String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.split(whereSeparator: \.isNewline) {
            if let port = parseLoopbackTCPPort(from: String(line)) {
                return port
            }
        }
        return nil
    }
}
