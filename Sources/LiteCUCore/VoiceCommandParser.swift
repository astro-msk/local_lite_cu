import Foundation

public struct ParsedVoiceCommand: Equatable, Sendable {
    public let command: String
    public let hasExecutionTrigger: Bool

    public var shouldExecute: Bool { hasExecutionTrigger && !command.isEmpty }
}

/// Parse only completed transcripts. A command phrase never supplies a missing task.
/// Whisper commonly writes spoken C U as “see you”; accept that alias only at
/// the beginning or end, so an embedded mention stays available for review.
public enum VoiceCommandParser {
    public static func parse(_ transcript: String) -> ParsedVoiceCommand {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trigger = try? NSRegularExpression(
            pattern: #"\b(?:cu|c[.\s]+u\.?)\s+start(?:\s+execution)?\b[.!]?|^\s*see you start(?: execution)?\b[.!]?|\bsee you start(?: execution)?[.!]?\s*$"#,
            options: .caseInsensitive
        ) else { return ParsedVoiceCommand(command: trimmed, hasExecutionTrigger: false) }
        let range = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
        guard trigger.firstMatch(in: transcript, range: range) != nil else {
            return ParsedVoiceCommand(command: trimmed, hasExecutionTrigger: false)
        }
        let command = trigger.stringByReplacingMatches(in: transcript, range: range, withTemplate: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,;:!?—–-"))
        return ParsedVoiceCommand(command: command, hasExecutionTrigger: true)
    }
}
