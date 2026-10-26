import Foundation
import LiteCUCore

/// Exports the production pure script generators; never creates a driver or sends an Apple Event.
@main
struct ExportArcScripts {
    @MainActor static func main() throws {
        let key = "__litecu_test"
        let token = "observation-one"
        func script(_ name: String, _ arguments: [String: JSONValue]) -> String {
            ArcBrowserDriver.actionScript(key: key, token: token, action: DesktopAction(name: name, arguments: .object(arguments)))
        }
        let text = "A quote: \"; a newline:\n; code-like text: ); globalThis.injected = true; //"
        let appleScriptText = "Quote: \"; backslash: \\; CR:\rLF:\nTAB:\t; emoji: 🐈; text: \" & do shell script \"echo wrong\""
        let scripts: [String: String] = [
            "snapshot": ArcBrowserDriver.snapshotScript(key: key, token: token),
            "next_snapshot": ArcBrowserDriver.snapshotScript(key: key, token: "observation-two"),
            "click": script("browser_click", ["element_id": .string(token + ":0")]),
            "missing_click": script("browser_click", ["element_id": .string(token + ":99")]),
            "type": script("browser_type", ["element_id": .string(token + ":0"), "text": .string(text)]),
            "scroll": script("browser_scroll", ["direction": .string("down"), "amount": .number(2)]),
            "unsupported": script("shell", ["element_id": .string(token + ":0")]),
            "expected_text": text,
            "applescript_expected_text": appleScriptText,
            "applescript_roundtrip": ArcBrowserDriver.bridgeScript(body:
                "return my jsonResult({|ok|:true, |text|:" + ArcBrowserDriver.appleScriptLiteral(appleScriptText) + "})"),
            "applescript_error": ArcBrowserDriver.bridgeScript(body: "error \"Fixture failure\" number -1743"),
            "applescript_target_syntax": ArcBrowserDriver.bridgeScript(body:
                ArcBrowserDriver.targetScript(windowID: "window-uuid", tabID: "tab-uuid") + "\nreturn my jsonResult({|ok|:true})")
        ]
        print(String(decoding: try JSONEncoder().encode(scripts), as: UTF8.self))
    }
}
