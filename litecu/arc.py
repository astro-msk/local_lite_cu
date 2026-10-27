"""Owned Arc task tabs, controlled by fixed AppleScript and packaged DOM scripts.

Required permissions: macOS System Settings > Privacy & Security > Automation >
Lite CU > Arc, and Arc > View > Developer > Allow JavaScript from Apple Events.
No command runs at import/construction. Closing the driver leaves its task window
open. Timeout/cancellation stops the sender, but cannot retract a delivered event.
"""
from __future__ import annotations

import asyncio
import json
import math
import os
import shutil
import sys
import tempfile
import time
import uuid
from importlib.resources import files
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit


ARC_ID = "company.thebrowser.Browser"
MAX_OUTPUT = 1_048_576
PERMISSIONS = (
    "Allow Lite CU → Arc in System Settings → Privacy & Security → Automation, "
    "and enable Arc → View → Developer → Allow JavaScript from Apple Events."
)


def _stale(message: str) -> Exception:
    # Keep importing this driver independent of the UI/engine's startup sequence.
    from .core import StaleObservation
    return StaleObservation(message)


def apple_literal(value: str) -> str:
    """AppleScript strings are not JSON strings; escape each grammar separately."""
    return '"' + (value.replace("\\", "\\\\").replace('"', '\\"')
                  .replace("\r", "\\r").replace("\n", "\\n").replace("\t", "\\t")) + '"'


def page_script(asset: str, parameters: dict[str, Any]) -> str:
    if asset not in {"arc_snapshot.js", "arc_action.js"}:
        raise ValueError("Unknown fixed Arc page operation.")
    source = files("litecu").joinpath("assets", asset).read_text(encoding="utf-8")
    if source.count("__LITECU_PARAMETERS__") != 1:
        raise RuntimeError("The packaged Arc page script is invalid.")
    return source.replace("__LITECU_PARAMETERS__", json.dumps(parameters, ensure_ascii=True, allow_nan=False))


def bridge_script(body: str, *, require_running: bool = True) -> str:
    running = (f'if application id "{ARC_ID}" is not running then error '
               '"Open Arc before running a background browser task."') if require_running else ""
    return f'''use framework "Foundation"
use scripting additions
on jsonResult(value)
    set jsonData to current application's NSJSONSerialization's dataWithJSONObject:value options:0 |error|:(missing value)
    if jsonData is missing value then error "Unable to encode the Arc response."
    return (current application's NSString's alloc()'s initWithData:jsonData encoding:(current application's NSUTF8StringEncoding)) as text
end jsonResult
on addedIDs(previousIDs, currentIDs)
    set foundIDs to {{}}
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
        {running}
        with timeout of 20 seconds
            {body}
        end timeout
    on error messageText number errorCode
        if operationPhase is not "" then set messageText to operationPhase & ": " & messageText
        return my jsonResult({{|ok|:false, |error|:messageText, |code|:errorCode}})
    end try
end run
'''


def creation_script(url: str) -> str:
    # Arc's make can return missing value. Only a single before/after ID addition
    # establishes ownership; no front/active/user-tab fallback is permitted.
    return f'''tell application id "{ARC_ID}"
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
    if (id of every window) does not contain createdWindowID then error "The new Arc task window closed before tab creation. Start a new task."
    set operationPhase to "Reading tabs in the new Arc task window"
    set previousTabIDs to id of every tab of window id createdWindowID
    set operationPhase to "Creating the Arc task tab"
    tell window id createdWindowID
        make new tab with properties {{URL:{apple_literal(url)}}}
    end tell
    set createdTabID to missing value
    set operationPhase to "Identifying the new Arc task tab"
    repeat 20 times
        if (id of every window) does not contain createdWindowID then error "The new Arc task window closed during tab creation. Start a new task."
        set addedTabIDs to my addedIDs(previousTabIDs, id of every tab of window id createdWindowID)
        if (count of addedTabIDs) > 1 then error "Arc tab creation was ambiguous: several new tabs appeared. Check Arc before retrying."
        if (count of addedTabIDs) is 1 then
            set createdTabID to item 1 of addedTabIDs
            exit repeat
        end if
        delay 0.1
    end repeat
    if createdTabID is missing value then error "Arc tab creation did not expose a new tab ID. Check the task window before retrying."
end tell
return my jsonResult({{|ok|:true, |window_id|:createdWindowID, |tab_id|:createdTabID}})'''


def target_script(window_id: str, tab_id: str) -> str:
    # Direct lexical specifiers avoid Arc's malformed returned object descriptors.
    return f'''tell application id "{ARC_ID}"
    set operationPhase to "Checking the owned Arc window"
    if (id of every window) does not contain {apple_literal(window_id)} then error "The task window was closed. Start a new task."
    set operationPhase to "Checking the owned Arc tab"
    if (id of every tab of window id {apple_literal(window_id)}) does not contain {apple_literal(tab_id)} then error "The task tab was closed. Start a new task."
end tell
'''


def navigation_script(window_id: str, tab_id: str, url: str) -> str:
    return target_script(window_id, tab_id) + f'''set operationPhase to "Navigating the Arc task tab"
tell application id "{ARC_ID}"
    set URL of tab id {apple_literal(tab_id)} of window id {apple_literal(window_id)} to {apple_literal(url)}
end tell
return my jsonResult({{|ok|:true}})'''


def evaluation_script(window_id: str, tab_id: str, javascript: str) -> str:
    target = f"tab id {apple_literal(tab_id)} of window id {apple_literal(window_id)}"
    return target_script(window_id, tab_id) + f'''tell application id "{ARC_ID}"
    set operationPhase to "Reading Arc tab loading status"
    if loading of {target} then return my jsonResult({{|ok|:true, |loading|:true}})
    set operationPhase to "Reading or interacting with the Arc page"
    set pageResult to execute {target} javascript {apple_literal(javascript)}
end tell
if pageResult is missing value or pageResult is "" then error "No page result. Enable Arc → View → Developer → Allow JavaScript from Apple Events, then retry."
return pageResult'''


def _validate(action: dict) -> tuple[str, dict]:
    if not isinstance(action, dict) or not isinstance(action.get("arguments", {}), dict):
        raise ValueError("Arc actions need a name and an arguments object.")
    name, args = action.get("name"), action.get("arguments", {})
    if not isinstance(name, str):
        raise ValueError("Arc action names must be strings.")

    def text(key: str, limit: int = 4000) -> str:
        value = args.get(key)
        if not isinstance(value, str) or not value or len(value) > limit or "\0" in value:
            raise ValueError(f"Invalid Arc {key}.")
        return value

    def number(key: str, low: float, high: float) -> float:
        value = args.get(key)
        if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value) or not low <= value <= high:
            raise ValueError(f"Invalid Arc {key}.")
        return value

    if name == "open_url":
        url = text("url")
        try:
            parsed = urlsplit(url)
            valid = parsed.scheme.lower() in {"http", "https"} and parsed.hostname and parsed.username is None and parsed.password is None
            _ = parsed.port
        except ValueError:
            valid = False
        if not valid or any(c.isspace() or ord(c) < 32 or 0xE200 <= ord(c) <= 0xE205 for c in url):
            raise ValueError("Only exact HTTP/HTTPS URLs without credentials or model citation markers are supported.")
        return name, {"url": url}
    if name in {"browser_click", "browser_type"}:
        result = {"element_id": text("element_id", 100)}
        if name == "browser_type":
            result["text"] = text("text")
        return name, result
    if name == "browser_scroll":
        direction, amount = text("direction", 10), number("amount", 1, 10)
        if direction not in {"up", "down", "left", "right"} or int(amount) != amount:
            raise ValueError("Arc scrolling needs a direction and a whole amount from 1 to 10.")
        return name, {"direction": direction, "amount": int(amount)}
    if name == "wait":
        return name, {"seconds": number("seconds", 0, 3)}
    if name == "observe":
        return name, {}
    raise ValueError(f"{name!r} is unavailable in Background Arc. Use a Desktop task for native controls.")


class ArcDriver:
    instructions = """EXECUTION TARGET: Background Arc browser; observations are text/DOM, not screenshots.
Only use open_url, browser_click(element_id), browser_type(element_id,text), browser_scroll(direction,amount), observe, wait, clarify, finish.
open_url creates or navigates this run's dedicated Arc tab; never use desktop coordinates or keyboard actions.
Element IDs are from the latest observation only. browser_type replaces text without submitting; click a visible submit button to submit.
Only visible top-document DOM is available: no browser chrome, dialogs, password/file inputs, cross-origin frames, canvas or trusted keyboard events.
For unsupported controls ask the user or explicitly switch to a Desktop task. Never claim success without observation.
Creating the dedicated task window may foreground Arc; subsequent operations do not activate or select user tabs."""

    def __init__(self, *, timeout: float = 25.0):
        self.timeout = timeout
        self._lock = asyncio.Lock()
        self._calls: set[asyncio.Task] = set()
        self._folders: set[Path] = set()
        self._generation = 0
        self.prepare()

    def prepare(self) -> None:
        if self._calls:
            raise RuntimeError("Stop the current Arc operation before preparing another task.")
        self._window_id: str | None = None
        self._tab_id: str | None = None
        self._token: str | None = None
        self._key = "__litecu_" + uuid.uuid4().hex
        self._generation += 1
        self._closed = False

    async def close(self) -> None:
        """Cancel local senders and remove temp files, without closing browser tabs."""
        self._closed = True
        self._token = None
        tasks = [task for task in self._calls if task is not asyncio.current_task()]
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        for folder in tuple(self._folders):
            shutil.rmtree(folder, ignore_errors=True)
            self._folders.discard(folder)

    async def check_connection(self) -> str:
        async with self._lock:
            result = await self._call(f'''tell application id "{ARC_ID}"
set windowCount to count of windows
end tell
return my jsonResult({{|ok|:true, |windows|:windowCount}})''')
            if type(result.get("windows")) is not int:
                raise RuntimeError("Arc did not return a window count.")
            return "Arc Automation connected. " + PERMISSIONS

    async def snapshot(self) -> dict:
        async with self._lock:
            self._ensure_open()
            self._generation += 1
            self._token = None
            if self._tab_id is None:
                return {"context": "Background Arc selected. No task tab yet. Use open_url to create a separate task window, or clarify the user's intent.",
                        "images": [], "summary": "Arc · ready to open a task tab", "generation": self._generation}
            token = str(uuid.uuid4())
            result = await self._evaluate(page_script("arc_snapshot.js", {"key": self._key, "token": token}))
            self._token = token
            return {"context": json.dumps(result, ensure_ascii=False), "images": [],
                    "summary": f"Arc · {result.get('title', 'Task page')} · {result.get('url', '')}",
                    "generation": self._generation}

    async def execute(self, action: dict) -> str:
        name, args = _validate(action)
        async with self._lock:
            self._ensure_open()
            if name == "observe":
                return "Requested a fresh Arc page observation."
            if name == "wait":
                await asyncio.sleep(args["seconds"])
                return "Waited for the Arc page."
            if name == "open_url":
                self._token = None
                if self._tab_id is None:
                    result = await self._call(creation_script(args["url"]))
                    window, tab = result.get("window_id"), result.get("tab_id")
                    if not all(isinstance(value, str) and 0 < len(value) <= 200 for value in (window, tab)):
                        raise RuntimeError("Arc returned no usable task identifiers. A window may have opened; check before retrying.")
                    self._window_id, self._tab_id = window, tab
                else:
                    window, tab = self._owned_ids()
                    await self._call(navigation_script(window, tab, args["url"]))
                return f"Navigated the dedicated Arc tab to {args['url']}. Verify the next observation."
            token, self._token = self._token, None
            if not token:
                raise _stale("Observe the Arc task tab before interacting.")
            result = await self._evaluate(page_script("arc_action.js", {
                "key": self._key, "token": token, "name": name, "arguments": args}))
            return str(result.get("message", "Dispatched a page interaction; verify the next observation."))

    def _ensure_open(self) -> None:
        if self._closed:
            raise RuntimeError("The Arc driver is closed. Prepare a new task first.")

    def _owned_ids(self) -> tuple[str, str]:
        if not self._window_id or not self._tab_id:
            raise RuntimeError("No owned task tab. Open a URL first.")
        return self._window_id, self._tab_id

    async def _evaluate(self, javascript: str) -> dict:
        window, tab = self._owned_ids()
        result = await self._call(evaluation_script(window, tab, javascript))
        if result.get("loading") is True:
            await asyncio.sleep(0.25)
            raise _stale("The Arc task tab is loading. Observe again before acting.")
        return result

    async def _call(self, body: str) -> dict:
        self._ensure_open()
        raw = await self._run_script(bridge_script(body))
        try:
            result = json.loads(raw)
            if isinstance(result, str):
                result = json.loads(result)
        except (ValueError, TypeError):
            raise RuntimeError("Arc returned an unreadable page result. " + PERMISSIONS) from None
        if not isinstance(result, dict):
            raise RuntimeError("Arc returned an invalid page result.")
        if result.get("ok") is not True:
            message = str(result.get("error", "Arc could not complete the operation."))[:1000]
            if result.get("kind") == "stale" and result.get("dispatched") is False:
                raise _stale(message)
            if result.get("code") == -1743:
                raise RuntimeError(PERMISSIONS)
            if result.get("code") == -1712:
                raise RuntimeError("Arc did not reply. A dispatched action may have happened; check the task tab before retrying.")
            raise RuntimeError(message)
        return result

    @staticmethod
    async def _stop_process(process: asyncio.subprocess.Process) -> None:
        if process.returncode is not None:
            return
        try:
            process.terminate()
        except ProcessLookupError:
            return
        try:
            await asyncio.wait_for(process.wait(), timeout=0.5)
        except asyncio.TimeoutError:
            try:
                process.kill()
            except ProcessLookupError:
                pass
            await process.wait()

    async def _run_script(self, script: str) -> str:
        if sys.platform != "darwin":
            raise RuntimeError("Background Arc control requires macOS.")
        task = asyncio.current_task()
        folder = Path(tempfile.mkdtemp(prefix="LiteCU-Arc-"))
        self._calls.add(task)
        self._folders.add(folder)
        process = None
        source, output, errors = (folder / name for name in ("bridge.applescript", "output.json", "error.txt"))
        try:
            for path, data in ((source, script.encode("utf-8")), (output, b""), (errors, b"")):
                with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as stream:
                    stream.write(data)
            with output.open("wb") as stdout, errors.open("wb") as stderr:
                launch = asyncio.create_task(asyncio.create_subprocess_exec(
                    "/usr/bin/osascript", "-l", "AppleScript", str(source),
                    stdin=asyncio.subprocess.DEVNULL, stdout=stdout, stderr=stderr))
                cancelled_during_launch = False
                while not launch.done():
                    try:
                        await asyncio.shield(launch)
                    except asyncio.CancelledError:
                        # Even repeated Stop/close signals must wait for the
                        # eventual process handle so its child can be terminated.
                        cancelled_during_launch = True
                process = launch.result()
                if cancelled_during_launch:
                    raise asyncio.CancelledError
                deadline = time.monotonic() + self.timeout
                while process.returncode is None:
                    if self._closed:
                        raise asyncio.CancelledError
                    if time.monotonic() >= deadline:
                        raise RuntimeError("Arc timed out. A dispatched action may have happened; check the task tab before retrying.")
                    if any(path.stat().st_size > MAX_OUTPUT for path in (output, errors)):
                        raise RuntimeError("Arc response exceeded the size limit.")
                    await asyncio.sleep(0.05)
                await process.wait()
                if any(path.stat().st_size > MAX_OUTPUT for path in (output, errors)):
                    raise RuntimeError("Arc response exceeded the size limit.")
                if process.returncode:
                    detail = errors.read_text(encoding="utf-8", errors="replace").strip()[-600:]
                    raise RuntimeError("The Arc AppleScript bridge failed. " + detail)
                return output.read_text(encoding="utf-8", errors="replace").strip()
        finally:
            cancelled_during_cleanup = False
            try:
                if process is not None:
                    cleanup = asyncio.create_task(self._stop_process(process))
                    while not cleanup.done():
                        try:
                            await asyncio.shield(cleanup)
                        except asyncio.CancelledError:
                            cancelled_during_cleanup = True
                    cleanup.result()
            finally:
                shutil.rmtree(folder, ignore_errors=True)
                self._folders.discard(folder)
                self._calls.discard(task)
            if cancelled_during_cleanup:
                raise asyncio.CancelledError
