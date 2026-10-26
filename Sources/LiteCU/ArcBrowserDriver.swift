import AppKit
import LiteCUCore

/// A task owns one Arc window/tab. Fixed page operations run through Apple Events;
/// this driver never posts desktop input or executes model-provided JavaScript.
@MainActor final class ArcBrowserDriver: DesktopDriving {
    private var windowID: String?
    private var tabID: String?
    private var observationToken = ""
    private var stateKey = "__litecu_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")

    var executionInstructions: String {
        """
        EXECUTION TARGET: Background Arc browser. You have a text/DOM observation, not a screenshot.
        Only use open_url, browser_click(element_id), browser_type(element_id,text), browser_scroll(direction,amount), observe, wait, clarify, finish.
        open_url creates or navigates this run's dedicated Arc tab; do not open_app or use desktop coordinates/keyboard actions.
        Element IDs are from the latest observation only. browser_type replaces the input's value without submitting; click a visible submit button to submit.
        Only visible top-document elements are available. No browser chrome, native dialogs, password/file inputs, cross-origin frames, canvas controls or trusted keyboard events. If unsupported, explain the limitation and ask for user input; never claim success.
        Opening the dedicated window/tab may briefly foreground Arc; later page operations do not select/activate tabs. Do not ask the user to bring Arc to the foreground for ordinary page operations.
        """
    }

    func prepareForRun() {
        windowID = nil; tabID = nil; observationToken = ""
        stateKey = "__litecu_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    func checkConnection() async throws -> String {
        let value = try await call(body: """
            tell application id "company.thebrowser.Browser"
                set windowCount to count of windows
            end tell
            return my jsonResult({|ok|:true, |windows|:windowCount})
            """)
        guard value["windows"].number != nil else { throw LiteCUError.message("Arc did not respond.") }
        return "Arc Automation connected. Enable Arc → View → Developer → Allow JavaScript from Apple Events for page controls."
    }

    func snapshot() async throws -> DesktopSnapshot {
        try Task.checkCancellation()
        guard tabID != nil else {
            return DesktopSnapshot(imageDataURL: "", width: 0, height: 0,
                context: "Background Arc is selected. No task tab yet. Use open_url with an HTTP/HTTPS address to create a separate task window, or clarify the user's intent before proceeding.",
                summary: "Arc · ready to open a task tab")
        }
        observationToken = UUID().uuidString
        let page = Self.snapshotScript(key: stateKey, token: observationToken)
        let value = try await evaluate(page)
        if value["loading"].bool == true {
            return DesktopSnapshot(imageDataURL: "", width: 0, height: 0, context: "Arc task tab is still loading. Use wait or observe; do not interact with stale elements.", summary: "Arc · page loading")
        }
        return DesktopSnapshot(imageDataURL: "", width: 0, height: 0,
            context: try value.encodedString(), summary: "Arc · \(value["title"].string ?? "Task page") · \(value["url"].string ?? "")")
    }

    func execute(_ action: DesktopAction) async throws -> String {
        try Task.checkCancellation()
        try ActionPolicy.validate(action)
        switch action.name {
        case "observe": return "Requested a fresh Arc page observation."
        case "wait":
            try await Task.sleep(for: .seconds(action.arguments["seconds"].number ?? 0))
            return "Waited for the Arc page."
        case "open_url":
            observationToken = ""
            let url = action.arguments["url"].string!
            if tabID == nil {
                let restoreLiteCU = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                defer { if restoreLiteCU { NSApp.activate(ignoringOtherApps: true) } }
                let result = try await call(body: Self.creationScript(url: url))
                guard let win = result["window_id"].string, !win.isEmpty,
                      let tab = result["tab_id"].string, !tab.isEmpty else {
                    throw LiteCUError.message("Arc did not return a task tab identifier. The window may have opened; check it before retrying.")
                }
                windowID = win; tabID = tab
            } else {
                let target = try targetIDs()
                _ = try await call(body: Self.navigationScript(windowID: target.windowID, tabID: target.tabID, url: url))
            }
            return "Navigated the dedicated Arc tab to \(url). Page content still needs verification."
        case "browser_click", "browser_type", "browser_scroll":
            guard !observationToken.isEmpty else { throw LiteCUError.message("Observe the Arc tab before interacting.") }
            let result = try await evaluate(Self.actionScript(key: stateKey, token: observationToken, action: action))
            guard result["loading"].bool != true else { throw LiteCUError.message("The Arc tab started loading. No input was sent; observe again.") }
            observationToken = ""
            return result["message"].string ?? "Dispatched page interaction; verify the next observation."
        default:
            throw LiteCUError.message("\(action.name) is unavailable in Background Arc. Use page element actions, or start a Desktop task for native controls.")
        }
    }

    private func targetIDs() throws -> (windowID: String, tabID: String) {
        guard let windowID, let tabID else {
            throw LiteCUError.message("No owned task tab. Open a URL first.")
        }
        return (windowID, tabID)
    }

    static func creationScript(url: String) -> String {
        // Arc may return missing value from make. Discover only IDs introduced by
        // this creation attempt; never infer ownership from front/active position.
        """
        tell application id "company.thebrowser.Browser"
            set operationPhase to "Reading Arc windows before creation"
            set previousWindowIDs to id of every window
            set operationPhase to "Creating the Arc task window"
            make new window
            set createdWindowID to missing value
            set operationPhase to "Identifying the new Arc task window"
            repeat 20 times
                set addedWindowIDs to my addedIDs(previousWindowIDs, id of every window)
                if (count of addedWindowIDs) > 1 then error "Arc window creation was ambiguous: several new windows appeared. Check Arc before retrying."
                if (count of addedWindowIDs) is 1 then
                    set createdWindowID to item 1 of addedWindowIDs
                    exit repeat
                end if
                delay 0.1
            end repeat
            if createdWindowID is missing value then error "Arc window creation did not expose a new window ID. A window may have opened; check Arc before retrying."
            if (id of every window) does not contain createdWindowID then error "The newly created Arc task window closed before tab creation. Start a new task."
            set operationPhase to "Reading tabs in the new Arc task window"
            set previousTabIDs to id of every tab of window id createdWindowID
            set operationPhase to "Creating the Arc task tab"
            tell window id createdWindowID
                make new tab with properties {URL:\(appleScriptLiteral(url))}
            end tell
            set createdTabID to missing value
            set operationPhase to "Identifying the new Arc task tab"
            repeat 20 times
                if (id of every window) does not contain createdWindowID then error "The newly created Arc task window closed during tab creation. Start a new task."
                set addedTabIDs to my addedIDs(previousTabIDs, id of every tab of window id createdWindowID)
                if (count of addedTabIDs) > 1 then error "Arc tab creation was ambiguous: several new tabs appeared in the task window. Check Arc before retrying."
                if (count of addedTabIDs) is 1 then
                    set createdTabID to item 1 of addedTabIDs
                    exit repeat
                end if
                delay 0.1
            end repeat
            if createdTabID is missing value then error "Arc tab creation did not expose a new tab ID in the task window. The window may be open; check Arc before retrying."
        end tell
        return my jsonResult({|ok|:true, |window_id|:createdWindowID, |tab_id|:createdTabID})
        """
    }

    static func targetScript(windowID: String, tabID: String) -> String {
        """
        tell application id "company.thebrowser.Browser"
            set operationPhase to "Checking the owned Arc window"
            if (id of every window) does not contain \(appleScriptLiteral(windowID)) then error "The task window was closed. Start a new task."
            set operationPhase to "Checking the owned Arc tab"
            if (id of every tab of window id \(appleScriptLiteral(windowID))) does not contain \(appleScriptLiteral(tabID)) then error "The task tab was closed. Start a new task."
        end tell
        """
    }

    static func navigationScript(windowID: String, tabID: String, url: String) -> String {
        targetScript(windowID: windowID, tabID: tabID) + """

        set operationPhase to "Navigating the Arc task tab"
        tell application id "company.thebrowser.Browser"
            set URL of tab id \(appleScriptLiteral(tabID)) of window id \(appleScriptLiteral(windowID)) to \(appleScriptLiteral(url))
        end tell
        return my jsonResult({|ok|:true})
        """
    }

    private func evaluate(_ javascript: String) async throws -> JSONValue {
        let target = try targetIDs()
        return try await call(body: Self.evaluationScript(windowID: target.windowID, tabID: target.tabID, javascript: javascript))
    }

    static func evaluationScript(windowID: String, tabID: String, javascript: String) -> String {
        // Keep lexical specifiers in each command. Getting an Arc window/tab object
        // first can return a malformed class-zero descriptor on current Arc builds.
        targetScript(windowID: windowID, tabID: tabID) + """

        tell application id "company.thebrowser.Browser"
            set operationPhase to "Reading Arc tab loading status"
            if loading of tab id \(appleScriptLiteral(tabID)) of window id \(appleScriptLiteral(windowID)) then return my jsonResult({|ok|:true, |loading|:true})
            set operationPhase to "Reading or interacting with the Arc page"
            set pageResult to execute tab id \(appleScriptLiteral(tabID)) of window id \(appleScriptLiteral(windowID)) javascript \(appleScriptLiteral(javascript))
        end tell
        if pageResult is missing value or pageResult is "" then error "No page result. Enable Arc → View → Developer → Allow JavaScript from Apple Events, then retry."
        return pageResult
        """
    }

    private func call(body: String) async throws -> JSONValue {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "company.thebrowser.Browser").isEmpty else {
            throw LiteCUError.message("Open Arc before running a background browser task.")
        }
        let raw = try await ArcScriptProcess.run(Self.bridgeScript(body: body))
        var result = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
        // Arc versions may encode the page's JSON text once more in their reply.
        if let nested = result?.string {
            result = try? JSONDecoder().decode(JSONValue.self, from: Data(nested.utf8))
        }
        guard let result else {
            throw LiteCUError.message("Arc returned an unreadable page result. Check Allow JavaScript from Apple Events in Arc → View → Developer.")
        }
        guard result["ok"].bool == true else {
            if result["code"].number == -1743 {
                throw LiteCUError.message("Allow Lite CU → Arc in System Settings → Privacy & Security → Automation, then retry.")
            }
            if result["code"].number == -1712 {
                throw LiteCUError.message("Arc did not reply to an Apple Event. A dispatched action may still have happened; check the task tab before retrying.")
            }
            throw LiteCUError.message(result["error"].string ?? "Arc could not complete the requested page operation.")
        }
        return result
    }

    static func bridgeScript(body: String) -> String {
        """
        use framework "Foundation"
        use scripting additions
        on jsonResult(value)
            set jsonData to current application's NSJSONSerialization's dataWithJSONObject:value options:0 |error|:(missing value)
            if jsonData is missing value then error "Unable to encode the Arc response."
            return (current application's NSString's alloc()'s initWithData:jsonData encoding:(current application's NSUTF8StringEncoding)) as text
        end jsonResult
        on addedIDs(previousIDs, currentIDs)
            set foundIDs to {}
            repeat with candidate in currentIDs
                set candidateID to contents of candidate
                if candidateID is missing value or class of candidateID is not text or candidateID is "" then error "Arc returned an invalid object identifier. Check Arc before retrying."
                if previousIDs does not contain candidateID and foundIDs does not contain candidateID then set end of foundIDs to candidateID
            end repeat
            return foundIDs
        end addedIDs
        on run
            set operationPhase to ""
            try
                with timeout of 20 seconds
                    \(body)
                end timeout
            on error messageText number errorCode
                if operationPhase is not "" then set messageText to operationPhase & ": " & messageText
                return my jsonResult({|ok|:false, |error|:messageText, |code|:errorCode})
            end try
        end run
        """
    }

    static func appleScriptLiteral(_ text: String) -> String {
        // AppleScript has its own string grammar; JSON escaping is not interchangeable.
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t") + "\""
    }

    private static func literal(_ text: String) -> String {
        // JSONEncoder escapes all input; no model or page text becomes executable code.
        (try? JSONValue.string(text).encodedString()) ?? "null"
    }

    static func snapshotScript(key: String, token: String) -> String {
        """
        JSON.stringify((() => {
          const key=\(literal(key)), token=\(literal(token));
          const visible=e=>{const r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>0&&r.height>0&&r.bottom>0&&r.right>0&&r.top<innerHeight&&r.left<innerWidth&&s.visibility!=='hidden'&&s.visibility!=='collapse'&&s.display!=='none'&&Number(s.opacity)>0;};
          const name=e=>(e.getAttribute('aria-label')||e.labels?.[0]?.innerText||e.innerText||e.getAttribute('placeholder')||e.getAttribute('title')||'').trim().slice(0,180);
          const nodes=Array.from(document.querySelectorAll('a[href],button,input,textarea,select,[role="button"],[role="link"],[contenteditable="true"]')).filter(visible).slice(0,180);
          const refs=new Map();
          const elements=nodes.map((e,i)=>{const id=token+':'+i, label=name(e);refs.set(id,{element:e,label,tag:e.tagName,href:e.tagName==='A'?e.href:'',type:e.type||''});return {id,role:e.getAttribute('role')||e.tagName.toLowerCase(),name:label,type:e.getAttribute('type'),disabled:!!e.disabled,href:e.tagName==='A'?e.href:undefined,value:e.type==='password'?undefined:(e.value||'').slice(0,240)};});
          window[key]={token,refs,url:location.href,name};
          return {ok:true,title:document.title,url:location.href,text:(document.body?.innerText||'').slice(0,16000),elements,limitations:'Visible top-level DOM only; no iframe, canvas, native controls or trusted input.'};
        })())
        """
    }

    static func actionScript(key: String, token: String, action: DesktopAction) -> String {
        let args = (try? action.arguments.encodedString()) ?? "{}"
        return """
        JSON.stringify((()=>{try{
          const s=window[\(literal(key))], token=\(literal(token)), a=\(args), action=\(literal(action.name));
          if(!s||s.token!==token||s.url!==location.href)throw new Error('Page changed; observe again before acting.');
          if(action==='browser_scroll'){
            const d=a.direction,amount=a.amount*300;
            window.scrollBy({left:d==='left'?-amount:d==='right'?amount:0,top:d==='up'?-amount:d==='down'?amount:0,behavior:'instant'});
            return {ok:true,message:'Scrolled the task page; verify the next observation.'};
          }
          const ref=s.refs.get(a.element_id), e=ref?.element;
          if(!e||!e.isConnected||s.name(e)!==ref.label||e.tagName!==ref.tag||(e.tagName==='A'?e.href:'')!==ref.href||(e.type||'')!==ref.type)throw new Error('Target changed; observe again before acting.');
          const r=e.getBoundingClientRect(),style=getComputedStyle(e);
          if(e.disabled||r.width<=0||r.height<=0||r.bottom<=0||r.right<=0||r.top>=innerHeight||r.left>=innerWidth||style.visibility==='hidden'||style.visibility==='collapse'||style.display==='none'||Number(style.opacity)<=0)throw new Error('Target is no longer available in the observed view.');
          if(e.tagName==='INPUT'&&['password','file','hidden'].includes(e.type))throw new Error('This input requires you to handle it directly.');
          if(action==='browser_click'){
            if(e.tagName==='A'){
              const url=new URL(e.href,location.href);
              if(!/^https?:$/.test(url.protocol)||url.username||url.password)throw new Error('Only HTTP/HTTPS links without embedded credentials are supported.');
            }
            if(e.tagName==='A'&&e.target&&e.target!=='_self')throw new Error('This link opens another tab. Use open_url with its observed HTTP/HTTPS address.');
            const x=(Math.max(0,r.left)+Math.min(innerWidth,r.right))/2,y=(Math.max(0,r.top)+Math.min(innerHeight,r.bottom))/2;
            const hit=document.elementFromPoint(x,y);
            if(!hit||(hit!==e&&!e.contains(hit)))throw new Error('Another element covers this target; observe again before clicking.');
            e.click();return {ok:true,message:'Dispatched a page click; success must be verified from the next observation.'};
          }
          if(action==='browser_type'){
            if(e.readOnly||!['INPUT','TEXTAREA'].includes(e.tagName))throw new Error('Only editable text inputs and textareas are supported.');
            if(e.tagName==='INPUT'&&!['text','search','email','url','tel','number'].includes(e.type))throw new Error('Unsupported input type.');
            const proto=e.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
            Object.getOwnPropertyDescriptor(proto,'value').set.call(e,a.text);
            e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));
            if(e.value!==a.text)throw new Error('The page did not retain the entered text; input may have partially applied.');
            return {ok:true,message:'Set the text field without submitting; verify the next observation.'};
          }
          throw new Error('Unsupported page action.');
        }catch(e){return {ok:false,error:String(e.message||e)};}})())
        """
    }
}

/// Runs only the application's fixed AppleScript bridge. Files are private, output bounded,
/// and cancellation stops the sender. A delivered Apple Event cannot be retracted.
private enum ArcScriptProcess {
    @MainActor static func run(_ script: String) async throws -> String {
        try Task.checkCancellation()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LiteCU-Arc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let source=folder.appendingPathComponent("bridge.applescript"), log=folder.appendingPathComponent("output.json"), errors=folder.appendingPathComponent("error.txt")
        for (file,data) in [(source,Data(script.utf8)),(log,Data()),(errors,Data())] {
            try data.write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        }
        let output=try FileHandle(forWritingTo:log), error=try FileHandle(forWritingTo:errors)
        defer {try? output.close();try? error.close()}
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/osascript")
        process.arguments=["-l","AppleScript",source.path];process.standardOutput=output;process.standardError=error;process.standardInput=FileHandle.nullDevice
        try process.run()
        do {
            let deadline=Date().addingTimeInterval(25)
            while process.isRunning {
                try Task.checkCancellation()
                guard Date()<deadline else {throw LiteCUError.message("Arc timed out. A dispatched action may still have happened; check the task tab before retrying.")}
                for file in [log,errors] {
                    let bytes=(try? FileManager.default.attributesOfItem(atPath:file.path)[.size] as? NSNumber)?.intValue ?? 0
                    guard bytes<1_048_576 else {throw LiteCUError.message("Arc response exceeded the size limit.")}
                }
                try await Task.sleep(for:.milliseconds(100))
            }
            try Task.checkCancellation()
        } catch {
            if process.isRunning {process.terminate()}
            if process.isRunning {Darwin.kill(process.processIdentifier,SIGKILL)}
            throw error
        }
        // A child can finish between polling intervals, so enforce the same bound
        // before reading its final stderr as well as its stdout.
        for file in [log,errors] {
            let bytes=(try? FileManager.default.attributesOfItem(atPath:file.path)[.size] as? NSNumber)?.intValue ?? 0
            guard bytes<=1_048_576 else {throw LiteCUError.message("Arc response exceeded the size limit.")}
        }
        guard process.terminationStatus==0 else {
            let detail=String((try? String(contentsOf:errors,encoding:.utf8))?.suffix(1200) ?? "")
            throw LiteCUError.message("The Arc AppleScript bridge failed. \(detail)")
        }
        let handle=try FileHandle(forReadingFrom:log);defer{try? handle.close()}
        let data=try handle.read(upToCount:1_048_577) ?? Data()
        guard data.count<=1_048_576 else{throw LiteCUError.message("Arc response exceeded the size limit.")}
        return String(decoding:data,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
    }
}
