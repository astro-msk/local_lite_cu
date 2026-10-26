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

    private func action(_ name: String, _ arguments: [String: JSONValue]) -> DesktopAction {
        DesktopAction(name: name, arguments: .object(arguments))
    }
}
