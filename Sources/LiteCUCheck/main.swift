import Foundation
import AppKit
import LiteCUCore

@main
struct LiteCUCheck {
    @MainActor static func main() async {
        do {
            if CommandLine.arguments.contains("--codex") {
                guard let path = CodexClient.discoverBinary() else { throw LiteCUError.message("No Codex binary found.") }
                print(try await CodexClient.connectionStatus(binaryPath: path))
                let model = CommandLine.arguments.contains("--gpt-6-sol") ? "gpt-6-sol" : "gpt-6.1-sol"
                let client = CodexClient(model: model, binaryPath: path)
                let vision = CommandLine.arguments.contains("--vision")
                var snapshot: DesktopSnapshot?
                if vision {
                    let image = NSImage(size: NSSize(width: 640, height: 320))
                    image.lockFocus()
                    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 640, height: 320).fill()
                    ("Vision check: 4729" as NSString).draw(at: NSPoint(x: 70, y: 150), withAttributes: [.font: NSFont.systemFont(ofSize: 42), .foregroundColor: NSColor.black])
                    image.unlockFocus()
                    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
                    let png = bitmap.representation(using: .png, properties: [:])!
                    snapshot = DesktopSnapshot(imageDataURL: "data:image/png;base64," + png.base64EncodedString(), width: 640, height: 320, context: "Synthetic test card, not the user's desktop.")
                }
                let text = try await client.generate(
                    instructions: "You are testing a structured integration. Do not use tools. Return action finish, reason integration check, requires_confirmation false, and all arguments null. " + (vision ? "In result, transcribe the digits visible on the image." : "Set result to Codex connection works."),
                    prompt: "Test the connection. Do not access files or control the desktop.",
                    snapshot: snapshot, schema: ActionPolicy.schema)
                let step = try DecidedStep.parse(text)
                guard step.action == nil else { throw LiteCUError.message("Smoke check did not return finish.") }
                if vision && !step.result.contains("4729") { throw LiteCUError.message("Vision check failed to read the test card.") }
                print("\(model): \(step.result)")
            } else {
                let runner = AgentRunner(driver: DemoDesktopDriver(), client: DemoModelClient(), configuration: RunConfiguration())
                runner.onEvent = { print("[\($0.role)] \($0.message)") }
                _ = try await runner.run(command: "Open Safari and search for SwiftUI tutorials")
                print("Demo integration check passed.")
            }
        } catch {
            FileHandle.standardError.write(Data("Check failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
