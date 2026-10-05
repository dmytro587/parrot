import XCTest

@testable import ParrotCore

final class WhistleTests: XCTestCase {
    private var whistle: TranscriptionModel { ModelRegistry.find("whistle")! }

    func testRegistry() {
        XCTAssertEqual(whistle.engine, .whistle)
        XCTAssertEqual(whistle.cactArtifact, "whistle.cact")
        XCTAssertFalse(whistle.recommended)
        XCTAssertTrue(whistle.isMultilingual)
        XCTAssertEqual(
            whistle.supportedLanguages,
            Set(["de", "en", "es", "fr", "it", "nl", "pl"])
        )
    }

    func testLanguagePlan() {
        let plan = SpokenLanguage.plan(setting: nil, spoken: ["en", "de"], model: whistle)
        XCTAssertEqual(plan, .detect(among: ["en", "de"]))
        XCTAssertEqual(
            WhistleTranscriber.language(for: TranscriptionContext(language: "de"), model: whistle),
            "de"
        )
        XCTAssertNil(
            WhistleTranscriber.language(
                for: TranscriptionContext(language: nil, spokenLanguages: ["en", "de"]),
                model: whistle
            )
        )
    }

    func testKeywordsFromVocabulary() {
        let ctx = TranscriptionContext(vocabulary: ["Parrot", "WhisperKit"])
        XCTAssertEqual(WhistleTranscriber.keywords(from: ctx), "Parrot\nWhisperKit")
    }
}
