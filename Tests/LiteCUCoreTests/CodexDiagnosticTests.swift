import Foundation
import Testing
@testable import LiteCUCore

@Suite
struct CodexDiagnosticTests {
    @Test(arguments: ["gpt-6-sol", "gpt-6.1-sol"])
    func capacityHasConciseModelSpecificGuidance(model: String) {
        let log = """
        OpenAI Codex CLI
        workdir: /private/temporary/run
        user
        Open the requested website.
        ERROR: The requested model is currently at capacity.
        ERROR: The requested model is currently at capacity.
        Warning: no last agent message; wrote empty output.
        """
        let label = model == "gpt-6-sol" ? "GPT-6 Sol" : "GPT-6.1 Sol"
        #expect(CodexClient.failureMessage(log: log, status: 1, model: model) ==
                "\(label) is at capacity. Try another model or retry shortly.")
    }

    @Test
    func selectsLastErrorAndStripsRepeatedPrefixesAndColor() {
        let log = "ERROR: Temporary retry failure\n\u{001B}[31mERROR: Error: Session expired; sign in again.\u{001B}[0m\nWarning: empty result"
        #expect(CodexClient.failureMessage(log: log, status: 1, model: nil) ==
                "Codex: Session expired; sign in again.")
    }

    @Test
    func echoedPromptCannotBecomeDiagnosticOrCapacityClaim() {
        let prompt = "Find an article about model capacity.\nERROR: This line is private user input."
        let log = "user\n\(prompt)\n\(prompt)\nWarning: no final answer"
        let result = CodexClient.failureMessage(log: log, status: 1, model: "gpt-6-sol", submittedInput: prompt)
        #expect(result == "Codex could not complete the request (status 1). Check the connection and selected model, then retry.")
        #expect(!result.contains("private user input"))
        #expect(!result.contains("capacity"))
    }

    @Test
    func unsupportedCLIArgumentRemainsActionable() {
        let log = "error: unexpected argument '--ignore-rules' found\nUsage: codex exec [OPTIONS]"
        #expect(CodexClient.failureMessage(log: log, status: 2, model: nil) ==
                "Codex: unexpected argument '--ignore-rules' found")
    }

    @Test
    func unknownFailureDoesNotExposeRawConfigurationOrPrompt() {
        let log = "workdir: /private/temporary/run\nmodel: hidden-config\nuser\nA private prompt\nFailed without diagnostic marker"
        let result = CodexClient.failureMessage(log: log, status: 7, model: nil)
        #expect(result.contains("status 7"))
        #expect(!result.contains("/private"))
        #expect(!result.contains("private prompt"))
        #expect(!result.contains("hidden-config"))
    }

    @Test
    func errorLengthIsBoundedAndUnicodeSafe() {
        let result = CodexClient.failureMessage(log: "ERROR: " + String(repeating: "🦊", count: 1_000), status: 1, model: nil)
        #expect(result.count == 400)
        #expect(result.hasPrefix("Codex: "))
        #expect(result.hasSuffix("…"))
    }

    @Test
    func missingLoginHasSpecificNextStep() {
        #expect(CodexClient.failureMessage(log: "Not logged in\n", status: 1, model: nil) ==
                "Codex is not signed in. Sign in with Codex and check the connection again.")
    }
}
