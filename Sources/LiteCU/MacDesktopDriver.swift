import AppKit
import ApplicationServices
import Carbon.HIToolbox
import LiteCUCore
import ScreenCaptureKit

/// All pointer coordinates are pixels in the most recent screenshot, with a top-left origin.
@MainActor
final class MacDesktopDriver: DesktopDriving {
    var onEmergencyStop: (() -> Void)?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var captureGeometry: CaptureGeometry?
    private var observedApplicationPID: pid_t?
    private var observedWindow: ObservedWindow?

    private struct CaptureGeometry {
        let displayID: CGDirectDisplayID
        let bounds: CGRect
        let width: Int
        let height: Int
    }

    private struct ObservedWindow {
        let element: AXUIElement
        let title: String?
        let bounds: CGRect

        func matches(_ other: ObservedWindow, compareTitle: Bool = true) -> Bool {
            CFEqual(element, other.element) && bounds == other.bounds && (!compareTitle || title == other.title)
        }
    }

    deinit {
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
    }

    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }
    static var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func requestScreenRecordingPermission() -> Bool { CGRequestScreenCaptureAccess() }

    func startEmergencyStopMonitor() {
        guard globalKeyMonitor == nil, localKeyMonitor == nil else { return }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.isStopShortcut(event) { self?.onEmergencyStop?() }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.isStopShortcut(event) else { return event }
            self?.onEmergencyStop?()
            return nil
        }
    }

    func stopEmergencyStopMonitor() {
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        globalKeyMonitor = nil
        localKeyMonitor = nil
    }

    private static func isStopShortcut(_ event: NSEvent) -> Bool {
        event.keyCode == UInt16(kVK_Escape)
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains([.command, .shift])
    }

    func prepareForRun() {
        captureGeometry = nil
        observedApplicationPID = nil
        observedWindow = nil
    }

    func snapshot() async throws -> DesktopSnapshot {
        try Task.checkCancellation()
        let previousTargetPID = observedApplicationPID
        captureGeometry = nil
        observedApplicationPID = nil
        observedWindow = nil
        guard Self.hasScreenRecordingPermission else {
            throw LiteCUError.message("Allow Screen Recording for LiteCU in System Settings → Privacy & Security, then reopen the app if macOS requests it.")
        }
        // Opening Lite CU to inspect progress is expected. Hand focus back before
        // taking a fresh observation; never reuse old coordinates for this handoff.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            NSApp.hide(nil)
            if let pid = previousTargetPID, let target = NSRunningApplication(processIdentifier: pid), !target.isTerminated {
                _ = target.activate(options: [])
            }
            for _ in 0..<20 {
                try Task.checkCancellation()
                if let front = NSWorkspace.shared.frontmostApplication,
                   front.processIdentifier != ProcessInfo.processInfo.processIdentifier { break }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        guard let application = NSWorkspace.shared.frontmostApplication else {
            throw LiteCUError.message("No foreground app is available. Bring the target app forward and try again.")
        }
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw LiteCUError.message("Could not return to the target app. Open the app you want to control, then retry this task.")
        }
        let window = try focusedWindow(application)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let capture = try captureDisplay(for: window, from: content.displays)
        let display = capture.display
        let displayID = display.displayID
        let bounds = capture.bounds
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = min(1440, display.width)
        configuration.height = max(1, Int((Double(display.height) * Double(configuration.width) / Double(display.width)).rounded()))
        configuration.showsCursor = true
        configuration.scalesToFit = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        guard CGDisplayIsActive(displayID) != 0, CGDisplayBounds(displayID) == bounds else {
            throw LiteCUError.message("The display configuration changed during capture. Observe again before acting.")
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
              windowsMatch(window, try focusedWindow(application)) else {
            throw LiteCUError.message("The foreground app changed during capture. Observe again before acting.")
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.78]) else {
            throw LiteCUError.message("Could not encode the desktop screenshot.")
        }
        captureGeometry = CaptureGeometry(displayID: displayID, bounds: bounds, width: image.width, height: image.height)
        observedApplicationPID = application.processIdentifier
        observedWindow = window
        let appName = application.localizedName ?? "Unknown"
        let bundleID = application.bundleIdentifier ?? "Unknown"
        let title = window?.title ?? "Unavailable"
        let displayContext = window == nil
            ? "Main display fallback: no focused window is available. Keyboard and pointer actions are unavailable until an app has a focused window."
            : "Captured the display containing the focused window (display \(displayID)). Only this display is visible."
        let context = "\(displayContext) Foreground app: \(appName). Bundle ID: \(bundleID). Window: \(title). Screenshot: \(image.width)×\(image.height) pixels. Coordinates use screenshot pixels, origin at top left."
        let windowTitle = window?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = windowTitle.isEmpty ? appName : "\(appName) · \(windowTitle)"
        return DesktopSnapshot(imageDataURL: "data:image/jpeg;base64," + data.base64EncodedString(), width: image.width, height: image.height, context: context, summary: summary)
    }

    private func captureDisplay(for window: ObservedWindow?, from displays: [SCDisplay]) throws -> (display: SCDisplay, bounds: CGRect) {
        let activeDisplays = displays.filter { CGDisplayIsActive($0.displayID) != 0 }
        guard let window else {
            guard let main = activeDisplays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                throw LiteCUError.message("The main display is unavailable for capture. Bring a target window forward and try again.")
            }
            return (main, CGDisplayBounds(main.displayID))
        }
        // AX window bounds and CG display bounds share global desktop coordinates.
        // Capture one entire display so screenshot pixels map directly to CG input.
        let intersections = activeDisplays.map { display in
            let bounds = CGDisplayBounds(display.displayID)
            let intersection = bounds.intersection(window.bounds)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            return (display: display, bounds: bounds, area: area)
        }
        guard let best = intersections.max(by: { $0.area < $1.area }), best.area > 0 else {
            throw LiteCUError.message("The focused window is not on an available display. Move it onto a connected display and run the task again.")
        }
        guard best.bounds.contains(window.bounds) else {
            throw LiteCUError.message("The focused window spans displays or extends offscreen. Move it fully onto one display and run the task again.")
        }
        return (best.display, best.bounds)
    }

    func execute(_ action: DesktopAction) async throws -> String {
        try Task.checkCancellation()
        guard let arguments = action.arguments.object else {
            throw LiteCUError.message("Action arguments must be a JSON object.")
        }
        if action.name == "observe" { return "Observation requested." }
        if action.name == "wait" {
            let seconds = try number("seconds", in: arguments, default: 1, range: 0...3)
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return "Waited \(seconds) seconds."
        }
        guard ["open_app", "open_url", "click", "type_text", "press_key", "scroll"].contains(action.name) else {
            throw LiteCUError.message("Unsupported desktop action: \(action.name).")
        }
        guard Self.hasAccessibilityPermission else {
            throw LiteCUError.message("Allow Accessibility for LiteCU in System Settings → Privacy & Security before running desktop actions.")
        }
        if ["click", "type_text", "press_key", "scroll"].contains(action.name) {
            try await restoreObservedApplication()
        }
        let result: String
        switch action.name {
        case "open_app":
            let bundleID = try string("bundle_id", in: arguments, maximum: 255)
            guard bundleID.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil,
                  let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                throw LiteCUError.message("No installed application matches bundle ID \(bundleID).")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
            result = "Opened \(bundleID)."
        case "open_url":
            let value = try string("url", in: arguments, maximum: 8_192)
            guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let components = URLComponents(string: value),
                  ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
                  let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil,
                  let url = components.url else {
                throw LiteCUError.message("open_url accepts an absolute HTTP or HTTPS URL without embedded credentials.")
            }
            guard NSWorkspace.shared.open(url) else { throw LiteCUError.message("macOS could not open the URL.") }
            result = "Opened \(url.absoluteString)."
        case "click":
            let point = try screenPoint(arguments)
            let buttonName = try string("button", in: arguments, default: "left", maximum: 10)
            guard ["left", "right"].contains(buttonName) else { throw LiteCUError.message("Click button must be left or right.") }
            let doubleClick: Bool
            if let value = arguments["double"] {
                guard let bool = value.bool else { throw LiteCUError.message("double must be a boolean.") }
                doubleClick = bool
            } else { doubleClick = false }
            let button: CGMouseButton = buttonName == "right" ? .right : .left
            let down: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
            let up: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
            let source = try eventSource()
            for click in 1...(doubleClick ? 2 : 1) {
                try Task.checkCancellation()
                try validateInputTarget(compareTitle: false)
                guard let press = CGEvent(mouseEventSource: source, mouseType: down, mouseCursorPosition: point, mouseButton: button),
                      let release = CGEvent(mouseEventSource: source, mouseType: up, mouseCursorPosition: point, mouseButton: button) else {
                    throw LiteCUError.message("Could not create a mouse event.")
                }
                press.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                release.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                press.post(tap: .cghidEventTap)
                release.post(tap: .cghidEventTap)
                if doubleClick && click == 1 { try await Task.sleep(nanoseconds: 80_000_000) }
            }
            result = doubleClick ? "Double-clicked the requested position." : "Clicked the requested position."
        case "type_text":
            let value = try string("text", in: arguments, maximum: 20_000, allowEmpty: true)
            let source = try eventSource()
            // Keep each Unicode event small and never split a UTF-16 surrogate pair.
            var chunk: [UniChar] = []
            for scalar in value.unicodeScalars {
                let units = Array(String(scalar).utf16)
                if chunk.count + units.count > 20 {
                    try postUnicode(chunk, source: source)
                    chunk.removeAll(keepingCapacity: true)
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                chunk.append(contentsOf: units)
            }
            if !chunk.isEmpty { try postUnicode(chunk, source: source) }
            result = "Typed \(value.count) characters."
        case "press_key":
            let combination = try string("key", in: arguments, maximum: 80)
            let (keyCode, modifiers) = try parseKey(combination)
            let source = try eventSource()
            guard let press = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
                  let release = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
                throw LiteCUError.message("Could not create a keyboard event.")
            }
            press.flags = modifiers
            release.flags = modifiers
            try Task.checkCancellation()
            try validateInputTarget(compareTitle: false)
            press.post(tap: .cghidEventTap)
            release.post(tap: .cghidEventTap)
            result = "Pressed \(combination)."
        case "scroll":
            let point = try screenPoint(arguments)
            let direction = try string("direction", in: arguments, maximum: 10)
            let amount = try number("amount", in: arguments, default: 3, range: 1...10)
            guard amount.rounded() == amount else { throw LiteCUError.message("Scroll amount must be an integer from 1 to 10.") }
            guard ["up", "down", "left", "right"].contains(direction) else {
                throw LiteCUError.message("Scroll direction must be up, down, left, or right.")
            }
            let lines = Int32(amount * 3)
            let vertical: Int32 = direction == "up" ? lines : (direction == "down" ? -lines : 0)
            let horizontal: Int32 = direction == "left" ? lines : (direction == "right" ? -lines : 0)
            let source = try eventSource()
            guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
                  let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0) else {
                throw LiteCUError.message("Could not create a scroll event.")
            }
            try Task.checkCancellation()
            try validateInputTarget(compareTitle: false)
            // macOS routes scrolling under the pointer. Approval moved the user's pointer to
            // LiteCU, so restore an explicit screenshot target rather than scrolling there.
            move.post(tap: .cghidEventTap)
            event.location = point
            event.post(tap: .cghidEventTap)
            result = "Scrolled \(direction)."
        default:
            throw LiteCUError.message("Unsupported desktop action.")
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        return result
    }

    private func screenPoint(_ arguments: [String: JSONValue]) throws -> CGPoint {
        let geometry = try validatedCaptureGeometry()
        let x = try number("x", in: arguments, range: 0...Double(geometry.width))
        let y = try number("y", in: arguments, range: 0...Double(geometry.height))
        guard x < Double(geometry.width), y < Double(geometry.height) else { throw LiteCUError.message("Click coordinates are outside the screenshot.") }
        return CGPoint(x: geometry.bounds.minX + x * geometry.bounds.width / Double(geometry.width),
                       y: geometry.bounds.minY + y * geometry.bounds.height / Double(geometry.height))
    }

    /// Approving an action activates LiteCU. Return input to the app the model actually observed.
    private func restoreObservedApplication() async throws {
        guard observedWindow != nil else {
            throw LiteCUError.message("No focused window was observed. Bring a target window forward and run the task again before sending keyboard or pointer input.")
        }
        _ = try validatedCaptureGeometry()
        guard let pid = observedApplicationPID,
              let target = NSRunningApplication(processIdentifier: pid), !target.isTerminated else {
            throw LiteCUError.message("The observed app is no longer available. Observe the desktop again before sending input.")
        }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if frontPID != pid {
            guard frontPID == ProcessInfo.processInfo.processIdentifier else {
                throw LiteCUError.message("The foreground app changed after observation. No input was sent. Bring the target app forward and run the task again.")
            }
            NSApp.hide(nil)
            guard target.activate(options: []) else {
                throw LiteCUError.message("Could not bring the observed app to the foreground. Activate it and observe again.")
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        try Task.checkCancellation()
        guard !target.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw LiteCUError.message("The observed app did not become active. No input was sent.")
        }
        try validateInputTarget()
    }

    private func validateInputTarget(compareTitle: Bool = true) throws {
        _ = try validatedCaptureGeometry()
        guard let pid = observedApplicationPID, observedWindow != nil,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated,
              windowsMatch(observedWindow, try focusedWindow(application), compareTitle: compareTitle) else {
            throw LiteCUError.message("The observed app or window changed. No further input was sent. Bring the target window forward and run the task again.")
        }
    }

    private func validatedCaptureGeometry() throws -> CaptureGeometry {
        guard let geometry = captureGeometry else {
            throw LiteCUError.message("Observe the desktop before sending keyboard or pointer input.")
        }
        guard CGDisplayIsActive(geometry.displayID) != 0,
              CGDisplayBounds(geometry.displayID) == geometry.bounds else {
            captureGeometry = nil
            throw LiteCUError.message("The captured display changed or disconnected. Observe again before sending input.")
        }
        return geometry
    }

    private func windowsMatch(_ first: ObservedWindow?, _ second: ObservedWindow?, compareTitle: Bool = true) -> Bool {
        switch (first, second) {
        case (.none, .none): return true
        case (.some(let first), .some(let second)): return first.matches(second, compareTitle: compareTitle)
        default: return false
        }
    }

    private func focusedWindow(_ application: NSRunningApplication) throws -> ObservedWindow? {
        guard Self.hasAccessibilityPermission else {
            throw LiteCUError.message("Accessibility access is required to verify the target window.")
        }
        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value)
        if status == .noValue || status == .attributeUnsupported { return nil }
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw LiteCUError.message("Could not verify the focused window. Bring the target app forward and try again.")
        }
        let window = value as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 1)
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            throw LiteCUError.message("Could not verify the target window's position and size. Try another window.")
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else {
            throw LiteCUError.message("The target window has invalid bounds. Observe again before sending input.")
        }
        var title: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
        return ObservedWindow(element: window, title: title as? String, bounds: CGRect(origin: position, size: size))
    }

    private func eventSource() throws -> CGEventSource {
        guard let source = CGEventSource(stateID: .privateState) else { throw LiteCUError.message("Could not create a desktop event source.") }
        return source
    }

    private func postUnicode(_ units: [UniChar], source: CGEventSource) throws {
        try Task.checkCancellation()
        // Typing can legitimately update the title (for example a note's first line). Keep
        // checking identity, geometry and focus between chunks; the next observation updates title.
        try validateInputTarget(compareTitle: false)
        guard let press = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let release = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw LiteCUError.message("Could not create a text event.")
        }
        units.withUnsafeBufferPointer { buffer in
            press.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
            release.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
        }
        press.post(tap: .cghidEventTap)
        release.post(tap: .cghidEventTap)
    }

    private func string(_ key: String, in arguments: [String: JSONValue], default fallback: String? = nil,
                        maximum: Int, allowEmpty: Bool = false) throws -> String {
        let value: String
        if let entry = arguments[key] {
            guard let text = entry.string else { throw LiteCUError.message("\(key) must be a string.") }
            value = text
        } else if let fallback { value = fallback }
        else { throw LiteCUError.message("Missing required argument: \(key).") }
        guard value.count <= maximum, allowEmpty || !value.isEmpty else {
            throw LiteCUError.message("\(key) must contain \(allowEmpty ? "0" : "1")–\(maximum) characters.")
        }
        return value
    }

    private func number(_ key: String, in arguments: [String: JSONValue], default fallback: Double? = nil,
                        range: ClosedRange<Double>) throws -> Double {
        let value: Double
        if let entry = arguments[key] {
            guard let number = entry.number else { throw LiteCUError.message("\(key) must be a number.") }
            value = number
        } else if let fallback { value = fallback }
        else { throw LiteCUError.message("Missing required argument: \(key).") }
        guard value.isFinite, range.contains(value) else { throw LiteCUError.message("\(key) must be between \(range.lowerBound) and \(range.upperBound).") }
        return value
    }

    private func parseKey(_ value: String) throws -> (CGKeyCode, CGEventFlags) {
        let parts = value.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, !key.isEmpty else { throw LiteCUError.message("Specify a key, for example cmd+l, return, or esc.") }
        var flags: CGEventFlags = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command", "meta": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: throw LiteCUError.message("Unsupported keyboard modifier: \(modifier).")
            }
        }
        let keys: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
            "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "space": kVK_Space,
            "esc": kVK_Escape, "escape": kVK_Escape, "delete": kVK_Delete, "backspace": kVK_Delete,
            "forwarddelete": kVK_ForwardDelete, "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "up": kVK_UpArrow, "down": kVK_DownArrow, "home": kVK_Home, "end": kVK_End,
            "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket,
            "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon,
            "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
            "`": kVK_ANSI_Grave, "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4,
            "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9,
            "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12
        ]
        guard let code = keys[key] else { throw LiteCUError.message("Unsupported key: \(key). Use type_text for arbitrary text.") }
        return (CGKeyCode(code), flags)
    }
}
