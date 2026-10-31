import XCTest
@testable import UIUICore

final class DictationPunctuationTests: XCTestCase {
    func testUserQuestionKeepsEveryWordAndInterjection() {
        XCTAssertEqual(DictationPunctuation.finalize("Okay, have we built everything"),
                       "Okay, have we built everything?")
    }

    func testClearlyDirectQuestionsReceiveQuestionMarks() {
        for question in ["can you check the build", "is this ready", "what time is the meeting",
                         "how does it work", "why did this fail", "how long does it take",
                         "Can’t you see the preview", "what model are we using", "which branch is ready",
                         "may I check the build"] {
            XCTAssertEqual(DictationPunctuation.finalize(question), question + "?")
        }
    }

    func testASRPeriodIsRepairedOnlyForClearQuestion() {
        XCTAssertEqual(DictationPunctuation.finalize("Okay, have we built everything."),
                       "Okay, have we built everything?")
        XCTAssertEqual(DictationPunctuation.finalize("The build is ready."), "The build is ready.")
    }

    func testExistingQuestionExclamationAndOpenEndedPunctuationSurvive() {
        for text in ["is this ready?", "Can you check the build!", "Maybe later...", "Maybe later…",
                     "The next step:", "Wait,", "Really?!"] {
            XCTAssertEqual(DictationPunctuation.finalize(text), text)
        }
    }

    func testStatementsAndShortCommandsGetOnlyTerminalPeriod() {
        for text in ["The build is ready", "okay", "ship it", "Have a look", "Do the build tomorrow",
                     "Do it now", "Do this tomorrow", "Do that again", "Have it ready by noon",
                     "Have this ready", "Don’t you worry", "Don’t you touch that",
                     "May you have a wonderful day", "May they rest in peace"] {
            XCTAssertEqual(DictationPunctuation.finalize(text), text + ".")
        }
    }

    func testIndirectQuestionsAndHowToHeadingAreNotPromotedToQuestions() {
        for text in ["I wonder why this failed", "what we need is more time", "how to build this",
                     "why this is broken", "what he is doing", "What matters is quality",
                     "What makes this work is teamwork", "What a day it has been",
                     "What is important is preserving the original words",
                     "What is required is a valid license"] {
            XCTAssertEqual(DictationPunctuation.finalize(text), text + ".")
            XCTAssertEqual(DictationPunctuation.finalize(text + "."), text + ".")
        }
    }

    func testASRCasingSpacingNumbersAndInteriorPunctuationRemainExact() {
        XCTAssertEqual(DictationPunctuation.finalize("  the BUILD has  42 items, and 3 remain\t "),
                       "  the BUILD has  42 items, and 3 remain.\t ")
        XCTAssertEqual(DictationPunctuation.finalize("We've built everything"), "We've built everything.")
    }

    func testQuotedQuestionsAndBackticksRemainLiteral() {
        for text in ["He said \"is this ready\"", "He asked “is this ready?”", "'can you check the build'",
                     "Use `isReady`", "He said \"what time is the meeting", "James' question"] {
            XCTAssertEqual(DictationPunctuation.finalize(text), text)
        }
    }

    func testURLsEmailsAndFilePathsAreNeverRewritten() {
        for text in ["https://example.com/build", "ravi@example.com", "/tmp/build", "Sources/App.swift",
                     "README.md", "example.com", "Check https://example.com/build", "version v2.3.4"] {
            XCTAssertEqual(DictationPunctuation.finalize(text), text)
        }
    }

    func testCodeAndNumericLiteralOutputsArePreserved() {
        for text in ["42", "3.14", "-12", "true", "nil", "let count = 42", "return value",
                     "print(value)", "value_name", "git status", "npm install", "swift build", "{\"ready\":true}", "```swift\nlet value = 1\n```"] {
            XCTAssertEqual(DictationPunctuation.finalize(text), text)
        }
    }

    func testMultilineAndMarkdownListsArePreserved() {
        for text in ["First line\nSecond line", "- check the build", "• check the build",
                     "1. check the build", "1) check the build", "# Build status"] {
            XCTAssertEqual(DictationPunctuation.finalize(text), text)
        }
    }

    func testMultipleClausesDoNotBorrowQuestionIntentFromEarlierSentence() {
        XCTAssertEqual(DictationPunctuation.finalize("Can you check the build? We are waiting"),
                       "Can you check the build? We are waiting.")
        XCTAssertEqual(DictationPunctuation.finalize("The build is ready. Can you check it"),
                       "The build is ready. Can you check it?")
        XCTAssertEqual(DictationPunctuation.finalize("The build is ready. Can you check it."),
                       "The build is ready. Can you check it?")
    }

    func testEmptyAndSilentInputRemainUnchanged() {
        for text in ["", " ", "\t\n  "] {
            XCTAssertEqual(DictationPunctuation.finalize(text), text)
        }
    }

    func testFinalizationIsStableAcrossRepeatedCaptureUpdates() {
        for text in ["Okay, have we built everything", "The build is ready", "ship it", "is this ready."] {
            let finalized = DictationPunctuation.finalize(text)
            XCTAssertEqual(DictationPunctuation.finalize(text), finalized)
            XCTAssertEqual(DictationPunctuation.finalize(finalized), finalized)
        }
    }
}
