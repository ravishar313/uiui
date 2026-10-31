import XCTest
@testable import UIUICore

final class DictationEditingTests: XCTestCase {
    func testActualUnpunctuatedCorrectionClearsEarlierHypothesis() {
        let raw = "This is a test of what I'm gonna write no actually scratch that this is a test of"
        XCTAssertEqual(DictationEditing.applyingCommands(to: raw), "this is a test of")
    }

    func testCorrectionPreservesEarlierSentenceAndReplacementPunctuation() {
        XCTAssertEqual(DictationEditing.applyingCommands(to: "Keep this. Wrong words scratch that corrected words, not those!"),
                       "Keep this. corrected words, not those!")
        XCTAssertEqual(DictationEditing.applyingCommands(to: "Keep this. Wrong sentence. No, actually, scratch that. Correct sentence."),
                       "Keep this. Correct sentence.")
        XCTAssertEqual(DictationEditing.applyingCommands(to: "Keep this! Wrong words actually scratch that right words?"),
                       "Keep this! right words?")
    }

    func testMultipleCorrectionsCannotDeleteBeforePreviousCorrection() {
        XCTAssertEqual(DictationEditing.applyingCommands(to: "Keep this. wrong scratch that first attempt scratch that final attempt"),
                       "Keep this. final attempt")
        XCTAssertEqual(DictationEditing.applyingCommands(to: "Keep this. wrong scratch that scratch that final"), "Keep this. final")
        XCTAssertEqual(DictationEditing.applyingCommands(to: "wrong scratch that one. two scratch that three"), "one. three")
    }

    func testCommandAtStartAndCommandWithoutReplacement() {
        XCTAssertEqual(DictationEditing.applyingCommands(to: "scratch that new words"), "new words")
        XCTAssertEqual(DictationEditing.applyingCommands(to: "NO SCRATCH THAT, New words"), "New words")
        XCTAssertEqual(DictationEditing.applyingCommands(to: "wrong words scratch that"), "")
        XCTAssertEqual(DictationEditing.applyingCommands(to: "scratch that"), "")
    }

    func testQuotedCommandsRemainLiteralIncludingIncompleteQuotes() {
        for raw in ["Write \"scratch that\" literally.", "Write 'scratch that' literally.",
                    "Write “scratch that” literally.", "Write ‘scratch that’ literally.",
                    "Write `scratch that` literally.", "Write \"scratch that later",
                    "Write \"He said \\\"scratch that\\\" literally.\""] {
            XCTAssertEqual(DictationEditing.applyingCommands(to: raw), raw)
        }
        XCTAssertEqual(DictationEditing.applyingCommands(to: "Keep \"scratch that\". wrong scratch that right"),
                       "Keep \"scratch that\". right")
        XCTAssertEqual(DictationEditing.applyingCommands(to: "James' idea scratch that revised idea"), "revised idea")
    }

    func testExplicitLiteralMentionRemainsLiteral() {
        for raw in ["The phrase scratch that is useful.", "Write the phrase: SCRATCH THAT today.",
                    "The phrase scratch that. Wrong scratch that Right."] {
            let expected = raw == "The phrase scratch that. Wrong scratch that Right." ? "The phrase scratch that. Right." : raw
            XCTAssertEqual(DictationEditing.applyingCommands(to: raw), expected)
        }
    }

    func testNegatedEditingMentionsRemainLiteralWithoutLosingCaptureText() {
        for raw in ["Please do not scratch that", "Keep the existing plan. Do not scratch that; send it tomorrow.",
                    "Don't scratch that", "Never scratch that", "Cannot scratch that", "Can't scratch that",
                    "You shouldn't scratch that", "We mustn’t scratch that", "I won't scratch that",
                    "Do not actually scratch that", "Not-actually scratch that", "Do not no actually scratch that"] {
            XCTAssertEqual(DictationEditing.applyingCommands(to: raw), raw)
            XCTAssertFalse(DictationEditing.applyingCommands(to: raw).isEmpty)
        }
        XCTAssertEqual(DictationEditing.applyingCommands(to: "Do not scratch that. Wrong scratch that Right."),
                       "Do not scratch that. Right.")
    }

    func testNegatedInstructionsToSayUseOrWritePhraseRemainLiteral() {
        for raw in ["Do not say scratch that", "Don't use scratch that", "Never write scratch that",
                    "Do not actually say scratch that", "Don't say actually scratch that"] {
            XCTAssertEqual(DictationEditing.applyingCommands(to: raw), raw)
        }
        XCTAssertEqual(DictationEditing.applyingCommands(to: "wrong no actually scratch that corrected"), "corrected")
        for raw in ["Actually this is the right plan.", "Never mind, keep the current plan."] {
            XCTAssertEqual(DictationEditing.applyingCommands(to: raw), raw)
        }
    }

    func testUnicodeNumbersNegationAndLineBreaksSurviveCorrection() {
        XCTAssertEqual(DictationEditing.applyingCommands(to: "रखो यह।\nगलत शब्द scratch that नहीं, ₹2,500 और café 🪷 — 3.14!"),
                       "रखो यह।\nनहीं, ₹2,500 और café 🪷 — 3.14!")
        XCTAssertEqual(DictationEditing.applyingCommands(to: "The amount is 3.14 scratch that 2.75, not 3.14."), "2.75, not 3.14.")
    }

    func testInternalDotsInURLsVersionsAndEmailsDoNotKeepPartOfWrongPhrase() {
        for wrong in ["Wrong uiui.app", "Wrong https://uiui.app/path", "Wrong ravi@example.com", "Wrong version v2.3.4"] {
            XCTAssertEqual(DictationEditing.applyingCommands(to: "Keep this. \(wrong) scratch that right"), "Keep this. right")
            XCTAssertEqual(DictationEditing.applyingCommands(to: "Keep this. \(wrong). Scratch that. Right."), "Keep this. Right.")
        }
        XCTAssertEqual(DictationEditing.applyingCommands(to: "Keep this. Wrong completed sentence. Scratch that right"), "Keep this. right")
    }

    func testCommonTitlesAndAbbreviationsAreNotSentenceBoundaries() {
        for title in ["Dr", "Mr", "Mrs", "Ms", "Prof", "Sr", "Jr", "St"] {
            XCTAssertEqual(DictationEditing.applyingCommands(to: "Keep this. Call \(title). Rao tomorrow scratch that call Asha"),
                           "Keep this. call Asha")
        }
        for phrase in ["Use e.g. the old build", "Use i.e. the old build", "Use apples vs. pears", "Use notes etc. in the plan"] {
            XCTAssertEqual(DictationEditing.applyingCommands(to: "Keep this. \(phrase) scratch that use the new build"),
                           "Keep this. use the new build")
        }
        XCTAssertEqual(DictationEditing.applyingCommands(to: "Keep Dr. Rao's plan. Wrong sentence scratch that Right."),
                       "Keep Dr. Rao's plan. Right.")
    }

    func testUnrecognizedGrammarAndProjectNamesAreUnchanged() {
        for raw in ["  Keep  these spaces\n", "ScratchThatProject is ready", "scratch_that is a project",
                    "scratch thatched roof", "scratch that_2", "pre-scratch that", "scratch that-project",
                    "unscratch that", "scratch this", "delete the previous sentence", "No, don't change anything."] {
            XCTAssertEqual(DictationEditing.applyingCommands(to: raw), raw)
        }
    }

    func testReprocessingFullHypothesisIsDeterministicAndOutputIsStable() {
        for raw in ["bad scratch that good", "Keep this. bad scratch that first scratch that second",
                    "Keep \"scratch that\". bad scratch that good", "The phrase scratch that. bad scratch that good"] {
            let once = DictationEditing.applyingCommands(to: raw)
            XCTAssertEqual(DictationEditing.applyingCommands(to: raw), once)
            XCTAssertEqual(DictationEditing.applyingCommands(to: once), once)
        }
    }
}
