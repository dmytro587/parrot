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
