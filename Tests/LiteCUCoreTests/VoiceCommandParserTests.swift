import Testing
@testable import LiteCUCore

@Suite struct VoiceCommandParserTests {
    @Test(arguments: [
        ("Open Safari. CU start execution.", "Open Safari"),
        ("Open example.com. See you start.", "Open example.com"),
        ("Open example.com. See you start execution.", "Open example.com"),
        ("See you start execution, open example.com", "open example.com"),
        ("Open Safari, cu START!", "Open Safari"),
        ("C U start execution, search for SwiftUI", "search for SwiftUI"),
        ("Search for cafés. C. U. start.", "Search for cafés"),
        ("CU start open Safari and search for SwiftUI", "open Safari and search for SwiftUI"),
        ("Open Safari CU start and search for SwiftUI", "Open Safari and search for SwiftUI")
    ])
    func explicitPhraseExecutesRemainingTask(_ sample: (String, String)) {
        let parsed = VoiceCommandParser.parse(sample.0)
        #expect(parsed.hasExecutionTrigger)
        #expect(parsed.shouldExecute)
        #expect(parsed.command == sample.1)
    }

    @Test(arguments: ["CU start", "cu start execution.", " C U START! ", "CU start; CU start execution.", "See you start execution", "See you start."])
    func phraseAloneNeverStartsAnEmptyTask(_ transcript: String) {
        let parsed = VoiceCommandParser.parse(transcript)
        #expect(parsed.hasExecutionTrigger)
        #expect(!parsed.shouldExecute)
        #expect(parsed.command.isEmpty)
    }

    @Test(arguments: [
        "Open Safari", "Execute cue starts", "CU starter", "CU starts execution",
        "Rescue start execution", "Tell me when I see you start a new project", "Cucumber starts here", ""
    ])
    func OrdinarySpeechAndSubstringsStayReviewable(_ transcript: String) {
        let parsed = VoiceCommandParser.parse(transcript)
        #expect(!parsed.hasExecutionTrigger)
        #expect(!parsed.shouldExecute)
        #expect(parsed.command == transcript)
    }
}
