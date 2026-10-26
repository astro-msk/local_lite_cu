import Foundation
import Testing
@testable import LiteCUCore

@Suite
struct ActionPolicyTests {
    @Test
    func testRejectsUnsupportedURLsAndEmbeddedCredentials() {
        for url in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,hello", "https://user:password@example.com", "https://"] {
            #expect(throws: (any Error).self) { try ActionPolicy.validate(action("open_url", ["url": .string(url)])) }
        }
        #expect(throws: Never.self) { try ActionPolicy.validate(action("open_url", ["url": .string("https://example.com/search?q=hello")])) }
    }

    @Test
    func testRejectsModelCitationMarkersInURLs() {
        for url in ["https://example.com/\u{E201}", "https://example.com/\u{E200}cite\u{E202}turn0search0\u{E201}"] {
            #expect(throws: (any Error).self) { try ActionPolicy.validate(action("open_url", ["url": .string(url)])) }
        }
        #expect(throws: Never.self) { try ActionPolicy.validate(action("open_url", ["url": .string("https://example.com/café")])) }
    }

    @Test
    func testRejectsUnknownActionAndMissingClickCoordinates() {
        #expect(throws: (any Error).self) { try ActionPolicy.validate(action("shell", ["command": .string("pwd")])) }
        #expect(throws: (any Error).self) { try ActionPolicy.validate(action("click", ["y": .number(10), "button": .string("left"), "double": .bool(false)])) }
        #expect(throws: (any Error).self) { try ActionPolicy.validate(action("click", ["x": .number(10), "y": .number(20), "button": .string("middle"), "double": .bool(false)])) }
    }

    @Test
    func testRejectsNonfiniteCoordinates() {
        for value in [Double.nan, Double.infinity, -Double.infinity, -1, 10_001] {
            #expect(throws: (any Error).self) { try ActionPolicy.validate(action("click", ["x": .number(value), "y": .number(20), "button": .string("left"), "double": .bool(false)])) }
        }
    }

    @Test
    func testRejectsInvalidScrollAndWaitValues() {
        #expect(throws: (any Error).self) { try ActionPolicy.validate(action("scroll", ["direction": .string("down"), "amount": .number(3)])) }
        for amount in [Double.nan, Double.infinity, -1, 0, 1.5, 11] {
            #expect(throws: (any Error).self) { try ActionPolicy.validate(action("scroll", ["x": .number(50), "y": .number(40), "direction": .string("down"), "amount": .number(amount)])) }
        }
        #expect(throws: (any Error).self) { try ActionPolicy.validate(action("scroll", ["x": .number(50), "y": .number(40), "direction": .string("diagonal"), "amount": .number(2)])) }
        for seconds in [Double.nan, Double.infinity, -1, 3.01] {
            #expect(throws: (any Error).self) { try ActionPolicy.validate(action("wait", ["seconds": .number(seconds)])) }
        }
        #expect(throws: Never.self) { try ActionPolicy.validate(action("scroll", ["x": .number(50), "y": .number(40), "direction": .string("left"), "amount": .number(10)])) }
        #expect(throws: Never.self) { try ActionPolicy.validate(action("wait", ["seconds": .number(0)])) }
    }

    @Test
    func testStructuredDecisionPreservesActionAndConfirmation() throws {
        let json = try JSONValue.object([
            "action": .string("click"), "reason": .string("Select the visible search field"),
            "result": .string(""), "requires_confirmation": .bool(true),
            "arguments": .object(["x": .number(120), "y": .number(48), "button": .string("left"), "double": .bool(false)])
        ]).encodedString()
        let decision = try DecidedStep.parse(json)
        #expect(decision.action?.name == "click")
        #expect(decision.action?.arguments["x"].number == 120)
        #expect(decision.action?.summary == "Select the visible search field")
        #expect(decision.requiresConfirmation)
        #expect(decision.result == "")
    }

    @Test
    func testFinishRequiresAResultAndMalformedResponsesNeverBecomeActions() throws {
        let finish = try JSONValue.object([
            "action": .string("finish"), "reason": .string("Verified the result"),
            "result": .string("The page is open."), "requires_confirmation": .bool(false), "arguments": .object([:])
        ]).encodedString()
        let decision = try DecidedStep.parse(finish)
        #expect(decision.action == nil)
        #expect(decision.result == "The page is open.")
        for invalid in ["not JSON", "{}", finish.replacingOccurrences(of: "The page is open.", with: "   "), finish.replacingOccurrences(of: "finish", with: "run_script")] {
            #expect(throws: (any Error).self) { try DecidedStep.parse(invalid) }
        }
    }

    @Test
    func testClarificationIsValidatedAndNeverBecomesDesktopAction() throws {
        let json = try JSONValue.object([
            "action": .string("clarify"), "reason": .string("A choice is missing"), "result": .string(""), "requires_confirmation": .bool(false),
            "arguments": .object(["question": .string(" Which account? "), "options": .array([.string(" Personal "), .string("Work")])])
        ]).encodedString()
        let decision = try DecidedStep.parse(json)
        #expect(decision.action == nil)
        #expect(decision.result.isEmpty)
        #expect(decision.clarification == ClarificationRequest(question: "Which account?", options: ["Personal", "Work"]))
        #expect(throws: (any Error).self) { try ActionPolicy.validate(action("clarify", ["question": .string("Which?"), "options": .array([.string("A"), .string("B")])])) }
    }

    @Test
    func testClarificationRejectsInvalidQuestionAndOptions() {
        let validOptions: JSONValue = .array([.string("One"), .string("Two")])
        let invalid: [[String: JSONValue]] = [
            [:], ["question": .null, "options": validOptions],
            ["question": .string(" \n "), "options": validOptions],
            ["question": .string(String(repeating: "q", count: 501)), "options": validOptions],
            ["question": .string("Which?"), "options": .string("One, Two")],
            ["question": .string("Which?"), "options": .array([.string("One")])],
            ["question": .string("Which?"), "options": .array((1...5).map { .string("Option \($0)") })],
            ["question": .string("Which?"), "options": .array([.string(" "), .string("Two")])],
            ["question": .string("Which?"), "options": .array([.number(1), .string("Two")])],
            ["question": .string("Which?"), "options": .array([.string("One"), .string(" one ")])],
            ["question": .string("Which?"), "options": .array([.string(String(repeating: "o", count: 121)), .string("Two")])]
        ]
        for arguments in invalid {
            #expect(throws: (any Error).self) { try ActionPolicy.clarification(from: arguments) }
        }
    }

    @Test
    func testBrowserActionsRequireBoundedElementIDsAndValidScroll() {
        for name in ["browser_click", "browser_type"] {
            for id in ["", String(repeating: "x", count: 101)] {
                #expect(throws: (any Error).self) { try ActionPolicy.validate(action(name, ["element_id": .string(id), "text": .string("hello")])) }
            }
        }
        #expect(throws: (any Error).self) { try ActionPolicy.validate(action("browser_type", ["element_id": .string("token:1")])) }
        #expect(throws: (any Error).self) { try ActionPolicy.validate(action("browser_type", ["element_id": .string("token:1"), "text": .string(String(repeating: "x", count: 4001))])) }
        for amount in [0.0, 1.5, 11.0] {
            #expect(throws: (any Error).self) { try ActionPolicy.validate(action("browser_scroll", ["direction": .string("down"), "amount": .number(amount)])) }
        }
        #expect(throws: (any Error).self) { try ActionPolicy.validate(action("browser_scroll", ["direction": .string("diagonal"), "amount": .number(2)])) }
        #expect(throws: Never.self) { try ActionPolicy.validate(action("browser_click", ["element_id": .string("token:1")])) }
        #expect(throws: Never.self) { try ActionPolicy.validate(action("browser_type", ["element_id": .string("token:1"), "text": .string("hello")])) }
        #expect(throws: Never.self) { try ActionPolicy.validate(action("browser_scroll", ["direction": .string("down"), "amount": .number(2)])) }
    }

    private func action(_ name: String, _ arguments: [String: JSONValue]) -> DesktopAction {
        DesktopAction(name: name, arguments: .object(arguments))
    }
}
