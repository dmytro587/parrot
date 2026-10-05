import CryptoKit
import Foundation

/// Phonon-2 weights under Application Support, same role as Whistle's `.cact`.
package enum PhononModelStore {
    static let hubRepo = "FermionResearch/Phonon-2"
    static let archiveName = "phonon-2.bps.tar.zst"
    static let unpackDirName = "model_phonon2_c4c_int6"
    /// Pinned digest from the model card; verified after download.
    static let archiveSHA256 =
        "98125795b6dda72f5c6eee9ba33d19815df65dcb18b50a357bf9f73c9935309e"

    private static let downloadBase = URL(
        string: "https://huggingface.co/FermionResearch/Phonon-2/resolve/main/")!

    /// Fermion cache root Parrot owns (`FERMION_CACHE_DIR` for the serve subprocess).
    package static func cacheRoot() throws -> URL {
        try Paths.prepareDirectory(
            Paths.appSupport.appendingPathComponent("models/fermion", isDirectory: true)
        )
    }

    package static func repoDirectory() throws -> URL {
        try cacheRoot()
            .appendingPathComponent("speech/FermionResearch__Phonon-2", isDirectory: true)
    }

    /// Where Fermion expects unpacked weights (`fermion models --json` layout).
    package static func modelDirectory() throws -> URL {
        try repoDirectory().appendingPathComponent(unpackDirName, isDirectory: true)
    }

    package static func isInstalled() -> Bool {
        guard let dir = try? modelDirectory() else { return false }
        return Self.hasManifests(in: dir)
    }

    private static func hasManifests(in dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("config.json").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("packed_manifest.json").path)
    }

    package static func downloadIfNeeded(progress: (@Sendable (Double) -> Void)? = nil) async throws
    {
        if isInstalled() {
            progress?(1)
            return
        }
        progress?(0)
        let root = try cacheRoot()
        let repoDir = try Paths.prepareDirectory(try repoDirectory())
        if hasManifests(in: repoDir) {
            try normalizeLayout(in: repoDir)
            if isInstalled() {
                progress?(1)
                return
            }
        }

        let archives = try Paths.prepareDirectory(
            root.appendingPathComponent("downloads", isDirectory: true)
        )
        let archive = archives.appendingPathComponent(archiveName)

        if !FileManager.default.fileExists(atPath: archive.path) {
            Log.info("downloading \(archiveName)...")
            let url = downloadBase.appendingPathComponent(archiveName)
            let (temp, response) = try await URLSession.shared.download(from: url)
            defer { try? FileManager.default.removeItem(at: temp) }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
            else {
                throw PhononError.weightsMissing("download failed for \(archiveName)")
            }
            try verifyArchive(at: temp)
            if FileManager.default.fileExists(atPath: archive.path) {
                try FileManager.default.removeItem(at: archive)
            }
            try FileManager.default.moveItem(at: temp, to: archive)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: archive.path)
        }

        progress?(0.85)
        try unpackArchive(at: archive, into: repoDir)
        try normalizeLayout(in: repoDir)
        progress?(1)
        guard isInstalled() else {
            throw PhononError.weightsMissing("unpack finished but \(unpackDirName) is incomplete")
        }
    }

    /// The Hugging Face archive is flat; Fermion reads `…/model_phonon2_c4c_int6/`.
    private static func normalizeLayout(in repoDir: URL) throws {
        let nested = repoDir.appendingPathComponent(unpackDirName, isDirectory: true)
        if hasManifests(in: nested) { return }
        guard hasManifests(in: repoDir) else { return }

        let fm = FileManager.default
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        for name in ["config.json", "packed_manifest.json", "model.fermion", "bps_manifest.json"] {
            let src = repoDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = nested.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.moveItem(at: src, to: dst)
        }
    }

    private static func verifyArchive(at url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard hex == archiveSHA256 else {
            throw PhononError.weightsMissing(
                "download digest mismatch (expected \(archiveSHA256.prefix(8))…)")
        }
    }

    private static func unpackArchive(at archive: URL, into repoDir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xf", archive.path, "-C", repoDir.path]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let err = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw PhononError.weightsMissing(
                "could not unpack \(archiveName)\(err.map { ": \($0)" } ?? "")")
        }
    }
}
