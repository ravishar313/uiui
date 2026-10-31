import XCTest
@testable import UIUICore

final class DictationCleanupTextTests: XCTestCase {
    func testSegmentsPreserveEveryCharacterAndOwnTheirWhitespace() {
        let source = " \talpha  beta\n\ngamma\t delta  "
        let segments = DictationCleanupText.segments(for: source, maximumUTF8Bytes: 11)
        XCTAssertEqual(segments, [
            .init(text: "", separator: " \t"),
            .init(text: "alpha  beta", separator: "\n\n"),
            .init(text: "gamma", separator: "\t "),
            .init(text: "delta", separator: "  ")
        ])
        XCTAssertEqual(segments.map(\.original).joined(), source)
    }

    func testEmptyAndWhitespaceOnlySourcesRemainLossless() {
        XCTAssertEqual(DictationCleanupText.segments(for: ""), [])
        let whitespace = "\n\t \u{00a0}\r\n"
        XCTAssertEqual(DictationCleanupText.segments(for: whitespace), [.init(text: "", separator: whitespace)])
        XCTAssertNil(DictationCleanupText.accepted("Invented words.", for: whitespace))
        XCTAssertNil(DictationCleanupText.accepted("", for: ""))
    }

    func testUTF8BudgetDoesNotSplitWordsOrGraphemes() {
        let source = "éé  漢字 👩🏽‍💻 cafe\u{301}"
        let segments = DictationCleanupText.segments(for: source, maximumUTF8Bytes: 7)
        XCTAssertEqual(segments.map(\.text), ["éé", "漢字", "👩🏽‍💻", "cafe\u{301}"])
        XCTAssertEqual(segments.map(\.original).joined(), source)
        XCTAssertEqual(segments.filter { $0.text.utf8.count > 7 }.map(\.text), ["👩🏽‍💻"])
    }

    func testOversizedWordIsIntactAndNeverSwallowsItsNeighbors() {
        let oversized = String(repeating: "x", count: 1_500)
        let source = "before " + oversized + "\n after"
        let segments = DictationCleanupText.segments(for: source)
        XCTAssertEqual(segments.map(\.text), ["before", oversized, "after"])
        XCTAssertEqual(segments.map(\.original).joined(), source)
        XCTAssertEqual(DictationCleanupText.segments(for: "one two", maximumUTF8Bytes: 0).map(\.text), ["one", "two"])
        XCTAssertEqual(DictationCleanupText.segments(for: "one two", maximumUTF8Bytes: .max).map(\.text), ["one two"])
    }

    func testLongUnicodeTranscriptHasNoTotalLengthTruncation() {
        let source = (0..<12_345).map { index in
            ["naïve", "हिन्दी", "漢字", "cafe\u{301}", "👩🏽‍💻"][index % 5] + [" ", "\t", "\n\n"][index % 3]
        }.joined()
        let segments = DictationCleanupText.segments(for: source)
        XCTAssertGreaterThan(segments.count, 100)
        XCTAssertTrue(segments.allSatisfy { $0.text.utf8.count <= 900 })
        XCTAssertEqual(segments.map(\.original).joined(), source)
    }

    func testCompletedSegmentsRemainStableAsStreamingTailGrows() {
        let words = ["a", "longer", "word", "éé", "漢字", "tail", "continues", "today"]
        var source = " \t"
        for word in words {
            let before = DictationCleanupText.segments(for: source, maximumUTF8Bytes: 12)
            source += word + "  "
            let after = DictationCleanupText.segments(for: source, maximumUTF8Bytes: 12)
            XCTAssertEqual(Array(after.prefix(max(0, before.count - 1))), Array(before.dropLast()))
        }
        XCTAssertEqual(DictationCleanupText.segments(for: source, maximumUTF8Bytes: 12).map(\.original).joined(), source)
    }

    func testRealProseAllowsOnlyPunctuationCasingAndWhitespaceCleanup() {
        XCTAssertEqual(DictationCleanupText.accepted("  Okay, have we built everything? \n", for: "okay have we built everything"),
                       "Okay, have we built everything?")
        XCTAssertEqual(DictationCleanupText.accepted("Ravi, NASA is ready; we have 42 items.", for: "ravi NASA is ready we have 42 items"),
                       "Ravi, NASA is ready; we have 42 items.")
        XCTAssertEqual(DictationCleanupText.accepted("Café, DON’T go!", for: "cafe\u{301} don't go"), "Café, DON’T go!")
        XCTAssertEqual(DictationCleanupText.accepted("Keep 👩🏽‍💻 here.", for: "keep 👩🏽‍💻 here"), "Keep 👩🏽‍💻 here.")
    }

    func testMissingAddedReorderedOrSubstitutedWordsAreRejected() {
        let source = "Ravi does not want the 42 blue items today"
        for candidate in [
            "Ravi does want the 42 blue items today.",
            "Ravi does not want the 42 blue items.",
            "Ravi does not want the 42 blue items today please.",
            "Ravi does not want the blue 42 items today.",
            "Ravi does not want the 43 blue items today.",
            "Rani does not want the 42 blue items today.",
            "", "   "
        ] {
            XCTAssertNil(DictationCleanupText.accepted(candidate, for: source), candidate)
        }
        XCTAssertNil(DictationCleanupText.accepted("One item.", for: "1 item"))
        XCTAssertNil(DictationCleanupText.accepted("We are ready.", for: "we we are ready"))
    }

    func testInternalPunctuationNumbersAndSymbolsCannotChangeMeaning() {
        for (source, candidate) in [
            ("don't stop", "Dont stop."),
            ("were ready", "We're ready."),
            ("twenty-one items", "Twenty one items."),
            ("keep -5 items", "Keep 5 items."),
            ("keep 1,000 items", "Keep 1000 items."),
            ("keep 5% today", "Keep 5 today."),
            ("keep 👩🏽‍💻 here", "Keep here.")
        ] {
            XCTAssertNil(DictationCleanupText.accepted(candidate, for: source), source)
        }
        XCTAssertEqual(DictationCleanupText.accepted("Keep -5 items, please.", for: "keep -5 items please"), "Keep -5 items, please.")
    }

    func testURLsEmailsPathsCodeAndModelMarkersAlwaysFallBack() {
        for source in [
            "visit https://example.com now", "email ravi@example.com", "open /tmp/build", "Sources/App.swift",
            "example.com", "version v2.3.4", "3.14 dollars", "let value = 42", "print(value)",
            "use `isReady`", "value_name", "git status", "Git status", "go test", "if ready", "for item", "while ready", "swift build", "return value", "true", "meet at 10:30",
            "<|assistant|> hello", "[INST] hello", "```swift\nlet n = 1\n```"
        ] {
            XCTAssertNil(DictationCleanupText.accepted(source, for: source), source)
        }
        XCTAssertNil(DictationCleanupText.accepted("Meet at 10 30.", for: "meet at 10:30"))
        for candidate in ["<answer>Hello world.</answer>", "[Hello world.]", "```Hello world.```", "Hello\u{200b} world."] {
            XCTAssertNil(DictationCleanupText.accepted(candidate, for: "hello world"), candidate)
        }
    }

    func testTruncatedLongOutputAndRunawayPunctuationAreRejected() {
        let original = Array(repeating: "keep every single word", count: 100).joined(separator: " ")
        let truncated = Array(repeating: "keep every single word", count: 99).joined(separator: " ") + "."
        XCTAssertNil(DictationCleanupText.accepted(truncated, for: original))
        XCTAssertNil(DictationCleanupText.accepted("Hello" + String(repeating: "!", count: 1_000), for: "hello"))
        XCTAssertNil(DictationCleanupText.accepted("...", for: "..."))
    }

    func testAnyCapitalOrMarkMakesTextFormattedAndOnlyBareLowercaseGoesToTheModel() {
        for text in ["Send it to Priya", "send it to Priya", "send it, please", "is it ready?", "go now.", "wow!", "ÉLÈVE"] {
            XCTAssertTrue(DictationCleanupText.isFormatted(text), text)
        }
        for text in ["send it to priya", "kal rahul se baat karo", "", "123 456"] {
            XCTAssertFalse(DictationCleanupText.isFormatted(text), text)
        }
    }
}
