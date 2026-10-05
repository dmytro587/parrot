import XCTest

@testable import ParrotCore

final class PhononConfigurationTests: XCTestCase {
    func testLoopbackURL() throws {
        let config = try PhononConfiguration(
            urlString: "http://127.0.0.1:8765", modelID: "phonon-2")
        XCTAssertEqual(config.baseURL.port, 8765)
    }

    func testRejectsNonLoopback() {
        XCTAssertThrowsError(
            try PhononConfiguration(urlString: "http://192.168.1.1:8000", modelID: "phonon-2")
        ) { error in
            XCTAssertTrue(error is PhononError)
        }
    }

    func testRejectsMissingPort() {
        XCTAssertThrowsError(
            try PhononConfiguration(urlString: "http://127.0.0.1", modelID: "phonon-2"))
    }
}

final class PhononRegistryTests: XCTestCase {
    func testPhonon2Entry() throws {
        let model = try XCTUnwrap(ModelRegistry.find("phonon-2"))
        XCTAssertEqual(model.engine, .phonon)
        XCTAssertEqual(model.languages, ["en"])
        XCTAssertFalse(model.isMultilingual)
        XCTAssertTrue(model.recommended)
        XCTAssertEqual(ModelRegistry.recommended()?.id, "phonon-2")
    }

    func testFactoryBuildsPhononTranscriber() throws {
        let model = try XCTUnwrap(ModelRegistry.find("phonon-2"))
        let transcriber = try TranscriberFactory.make(model: model)
        XCTAssertTrue(transcriber is PhononTranscriber)
    }
}

final class WAVEncoderTests: XCTestCase {
    func testEncodesRIFFHeader() {
        let wav = WAVEncoder.data(samples: [-2, 0, 2], sampleRate: 16_000)
        XCTAssertGreaterThan(wav.count, 44)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")
    }
}

final class PhononHotwordTests: XCTestCase {
    func testHotwordsFromVocabulary() {
        let ctx = TranscriptionContext(vocabulary: ["Parrot", "Phonon"])
        XCTAssertEqual(PhononTranscriber.hotwords(from: ctx), "Parrot, Phonon")
    }
}

final class PhononDependencyInstallerTests: XCTestCase {
    func testPythonVersionParsing() {
        guard let python = PhononDependencyInstaller.locatePython() else {
            throw XCTSkip("no Python 3.10+ on PATH")
        }
        let version = PhononDependencyInstaller.pythonVersion(at: python)
        XCTAssertGreaterThanOrEqual(version.0, 3)
        XCTAssertGreaterThanOrEqual(version.1, 10)
    }
}

final class PhononSupportTests: XCTestCase {
    func testParseServePortFromFermionLine() {
        let line =
            "[fermion] serving FermionResearch/Phonon-2 (sha 98125795) on http://127.0.0.1:59280/v1"
        XCTAssertEqual(PhononSupport.parseServePort(from: line), 59_280)
    }

    func testParseServePortIgnoresUnrelatedLines() {
        XCTAssertNil(PhononSupport.parseServePort(from: "[fermion] decode backend: mlx"))
    }

    func testParseServePortFromStderrStyleLine() {
        let line =
            "[fermion] OpenAI-compatible: set base_url=http://127.0.0.1:59747/v1 (api key: any)"
        XCTAssertEqual(PhononSupport.parseServePort(from: line), 59_747)
    }

    func testParseLoopbackPortFromLsofLine() {
        let line = "Python 5814 beeshop 4u IPv4 0x0 TCP localhost:60019 (LISTEN)"
        XCTAssertEqual(PhononSupport.parseLoopbackTCPPort(from: line), 60_019)
    }
}

final class PhononModelStoreLayoutTests: XCTestCase {
    func testNormalizeLayoutMovesFlatUnpackIntoNestedDir() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-phonon-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("{}".utf8).write(to: root.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("packed_manifest.json"))

        try PhononModelStore.normalizeLayout(in: root)

        let nested = root.appendingPathComponent("model_phonon2_c4c_int6", isDirectory: true)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: nested.appendingPathComponent("config.json").path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("config.json").path))
    }
}
