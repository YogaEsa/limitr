import XCTest
@testable import LimitrCore

final class ActivationPromptTests: XCTestCase {
    func testAsksBeforeHandingTheServiceToAnotherAccount() throws {
        let prompt = try XCTUnwrap(
            ActivationPrompt.forActivating(
                accountName: "Work Plus",
                serviceLabel: "Claude Code",
                isAlreadyActive: false
            )
        )

        XCTAssertEqual(prompt.title, #"Make "Work Plus" the active Claude Code account?"#)
        XCTAssertEqual(prompt.confirmTitle, "Make Active")
    }

    func testSaysNothingAboutSessionsThatAreAlreadyRunning() throws {
        // The panel is the only place that tells the user how far a switch reaches, and it
        // reaches new terminals and the next command in open ones — never a `claude` that is
        // already running, which read its credential at exec time. Promising otherwise would
        // send someone back to a session that is quietly still spending the old account.
        let prompt = try XCTUnwrap(
            ActivationPrompt.forActivating(
                accountName: "Work Plus",
                serviceLabel: "Claude Code",
                isAlreadyActive: false
            )
        )

        XCTAssertTrue(prompt.message.contains("New terminals"))
        XCTAssertTrue(prompt.message.contains("restart"))
    }

    /// The bar is inline on a 358pt panel, so the message is the one thing that decides
    /// how tall it gets. At full width this is two or three lines; the copy it replaced
    /// ran to nine, because it was both longer and laid out beside the buttons, and a
    /// confirmation that fills the panel reads as an error rather than a question.
    func testKeepsTheMessageShortEnoughToStayTwoOrThreeLines() throws {
        let prompt = try XCTUnwrap(
            ActivationPrompt.forActivating(
                accountName: "Work Plus",
                serviceLabel: "ChatGPT Codex",
                isAlreadyActive: false
            )
        )

        XCTAssertLessThanOrEqual(prompt.message.count, 130)
    }

    func testDoesNotAskWhenTheAccountIsAlreadyTheActiveOne() {
        // Clicking the account that already holds the service is how the user says "stop
        // reassigning this" — see `setActive`. That is not a switch, so a confirmation there
        // is pure friction.
        XCTAssertNil(
            ActivationPrompt.forActivating(
                accountName: "Work Plus",
                serviceLabel: "Claude Code",
                isAlreadyActive: true
            )
        )
    }

    func testFallsBackToAGenericPhraseWhenTheAccountHasNoName() throws {
        // The name is an editable text field on the row, so it can be empty at the moment
        // the star is clicked. `Make "" the active …` is worse than not naming it at all.
        let prompt = try XCTUnwrap(
            ActivationPrompt.forActivating(
                accountName: "   ",
                serviceLabel: "ChatGPT Codex",
                isAlreadyActive: false
            )
        )

        XCTAssertEqual(prompt.title, "Make this the active ChatGPT Codex account?")
    }
}
