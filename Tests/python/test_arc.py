"""Arc tests use fake processes/DOMs. Targeted AppleScripts are only compiled."""
import asyncio
import json
import shutil
import subprocess
import sys
from pathlib import Path
from unittest.mock import AsyncMock

import pytest

from litecu.arc import (ArcDriver, MAX_OUTPUT, _validate, apple_literal, bridge_script,
                       creation_script, evaluation_script, navigation_script, page_script, target_script)
from litecu.core import Engine, StaleObservation


def action(name, **arguments):
    return {"name": name, "arguments": arguments}


def fake_driver(*responses):
    driver = ArcDriver()
    driver._run_script = AsyncMock(side_effect=[json.dumps(value) for value in responses])
    return driver


def test_constructor_and_prepare_have_no_browser_side_effects():
    driver = ArcDriver()
    old_key = driver._key
    driver.prepare()
    assert driver._key != old_key
    assert driver._window_id is driver._tab_id is driver._token is None
    assert not driver._calls and not driver._folders


@pytest.mark.parametrize("item", [
    action("open_url", url="javascript:alert(1)"), action("open_url", url="file:///etc/passwd"),
    action("open_url", url="https://name:secret@example.com"), action("open_url", url="https://example.com/\ue201"),
    action("open_url", url="https://example.com/\n"), action("open_url", url="https://example.com:99999"),
    action("browser_type", element_id="id", text=""), action("browser_click", element_id="x" * 101),
    action("browser_scroll", direction="down", amount=1.5), action("browser_scroll", direction="down", amount=True),
    action("browser_scroll", direction="diagonal", amount=1), action("wait", seconds=float("nan")),
    action("wait", seconds=4), action("execute_javascript", javascript="document.body.remove()"),
    action(["browser_click"], element_id="id"),
])
def test_invalid_actions_rejected_before_dispatch(item):
    with pytest.raises(ValueError):
        _validate(item)


async def test_no_task_snapshot_does_not_touch_arc():
    driver = fake_driver()
    result = await driver.snapshot()
    assert result["images"] == [] and "No task tab" in result["context"]
    driver._run_script.assert_not_awaited()


async def test_create_owned_target_then_snapshot_and_one_use_action():
    driver = fake_driver({"ok": True, "window_id": "owned-window", "tab_id": "owned-tab"},
                         {"ok": True, "title": "Example", "url": "https://example.com", "elements": []},
                         {"ok": True, "message": "clicked"})
    await driver.execute(action("open_url", url="https://example.com"))
    snapshot = await driver.snapshot()
    token = driver._token
    assert snapshot["images"] == [] and "Example" in snapshot["summary"]
    assert await driver.execute(action("browser_click", element_id=token + ":0")) == "clicked"
    assert driver._token is None
    with pytest.raises(StaleObservation):
        await driver.execute(action("browser_click", element_id=token + ":0"))
    assert driver._run_script.await_count == 3
    second_script = driver._run_script.await_args_list[1].args[0]
    assert 'tab id "owned-tab" of window id "owned-window"' in second_script


async def test_next_navigation_reuses_only_owned_ids():
    driver = fake_driver({"ok": True, "window_id": "owned-window", "tab_id": "owned-tab"}, {"ok": True})
    await driver.execute(action("open_url", url="https://example.com"))
    await driver.execute(action("open_url", url="https://example.org"))
    script = driver._run_script.await_args_list[1].args[0]
    assert "make new" not in script and 'URL of tab id "owned-tab" of window id "owned-window"' in script


async def test_creation_ambiguity_does_not_adopt_existing_target():
    driver = fake_driver({"ok": False, "error": "Arc window creation was ambiguous"})
    with pytest.raises(RuntimeError, match="ambiguous"):
        await driver.execute(action("open_url", url="https://example.com"))
    assert driver._window_id is driver._tab_id is None


async def test_loading_snapshot_and_input_are_stale_and_forget_token():
    driver = fake_driver({"ok": True, "loading": True}, {"ok": True, "loading": True})
    driver._window_id, driver._tab_id, driver._token = "owned-w", "owned-t", "old-token"
    with pytest.raises(StaleObservation, match="loading"):
        await driver.snapshot()
    assert driver._token is None
    driver._token = "fresh-token"
    with pytest.raises(StaleObservation, match="loading"):
        await driver.execute(action("browser_scroll", direction="down", amount=1))
    assert driver._token is None


@pytest.mark.parametrize("dispatched,expected", [(False, StaleObservation), (True, RuntimeError)])
async def test_only_pre_dispatch_failures_are_safe_to_retry(dispatched, expected):
    driver = fake_driver({"ok": False, "kind": "stale", "dispatched": dispatched, "error": "Target changed"})
    driver._window_id, driver._tab_id, driver._token = "owned-w", "owned-t", "token"
    with pytest.raises(expected) as caught:
        await driver.execute(action("browser_click", element_id="token:0"))
    if dispatched:
        assert not isinstance(caught.value, StaleObservation)
    assert driver._token is None


async def test_close_only_cleans_local_state_and_prepare_can_start_another_run():
    driver = fake_driver()
    driver._window_id, driver._tab_id = "owned-w", "owned-t"
    await driver.close()
    driver._run_script.assert_not_awaited()
    with pytest.raises(RuntimeError, match="closed"):
        await driver.snapshot()
    driver.prepare()
    assert "No task tab" in (await driver.snapshot())["context"]


async def test_json_string_response_and_permission_error():
    driver = fake_driver(json.dumps({"ok": True, "windows": 2}), {"ok": False, "code": -1743})
    assert "connected" in await driver.check_connection()
    with pytest.raises(RuntimeError, match="Automation"):
        await driver.check_connection()


async def test_engine_accepts_arc_capture_generation_and_verifies_owned_page():
    driver = fake_driver({"ok": True, "window_id": "owned-w", "tab_id": "owned-t"},
                         {"ok": True, "title": "Example", "url": "https://example.com", "elements": []})
    model = type("Model", (), {})()
    model.decide = AsyncMock(side_effect=[
        {"kind": "act", "confidence": 1, "actions": [action("open_url", url="https://example.com")]},
        {"kind": "finish", "result": "Verified Example"},
    ])
    events = []
    engine = Engine(model, {"arc": driver}, events.append, {"target": "arc", "approval": "full"})
    assert await asyncio.wait_for(engine.run("Open example.com"), timeout=2) == "Verified Example"
    assert model.decide.await_count == 2
    assert events[-1]["status"] == "complete"
    assert driver._closed


class FakeProcess:
    def __init__(self, returncode=None, ignore_term=False):
        self.returncode = returncode
        self.ignore_term = ignore_term
        self.terminated = self.killed = False

    async def wait(self):
        while self.returncode is None:
            await asyncio.sleep(0.001)
        return self.returncode

    def terminate(self):
        self.terminated = True
        if not self.ignore_term:
            self.returncode = -15

    def kill(self):
        self.killed = True
        self.returncode = -9


async def test_process_io_is_private_bounded_and_cleaned(monkeypatch):
    driver = ArcDriver()
    observed = {}

    async def spawn(*args, **kwargs):
        observed["source"] = Path(args[-1])
        assert args[:3] == ("/usr/bin/osascript", "-l", "AppleScript")
        assert observed["source"].stat().st_mode & 0o777 == 0o600
        assert observed["source"].parent.stat().st_mode & 0o777 == 0o700
        kwargs["stdout"].write(b'{"ok":true}')
        kwargs["stdout"].flush()
        return FakeProcess(0)

    monkeypatch.setattr("litecu.arc.sys.platform", "darwin")
    monkeypatch.setattr("litecu.arc.asyncio.create_subprocess_exec", spawn)
    assert json.loads(await driver._run_script("fixed script")) == {"ok": True}
    assert not observed["source"].parent.exists()
    assert not driver._calls and not driver._folders


@pytest.mark.parametrize("stream", ["stdout", "stderr"])
async def test_fast_exit_cannot_bypass_output_bound(monkeypatch, stream):
    driver = ArcDriver()

    async def spawn(*args, **kwargs):
        kwargs[stream].write(b"x" * (MAX_OUTPUT + 1))
        kwargs[stream].flush()
        return FakeProcess(0)

    monkeypatch.setattr("litecu.arc.sys.platform", "darwin")
    monkeypatch.setattr("litecu.arc.asyncio.create_subprocess_exec", spawn)
    with pytest.raises(RuntimeError, match="size limit"):
        await driver._run_script("fixed script")
    assert not driver._calls and not driver._folders


async def test_timeout_terminates_sender_and_cleans_files(monkeypatch):
    process, driver = FakeProcess(), ArcDriver(timeout=0.01)
    monkeypatch.setattr("litecu.arc.sys.platform", "darwin")
    monkeypatch.setattr("litecu.arc.asyncio.create_subprocess_exec", AsyncMock(return_value=process))
    with pytest.raises(RuntimeError, match="timed out"):
        await driver._run_script("fixed script")
    assert process.terminated and not driver._folders


async def test_cancel_during_spawn_does_not_orphan_child(monkeypatch):
    started, allow_spawn = asyncio.Event(), asyncio.Event()
    process, driver = FakeProcess(), ArcDriver()

    async def spawn(*args, **kwargs):
        started.set()
        await allow_spawn.wait()
        return process

    monkeypatch.setattr("litecu.arc.sys.platform", "darwin")
    monkeypatch.setattr("litecu.arc.asyncio.create_subprocess_exec", spawn)
    task = asyncio.create_task(driver._run_script("fixed script"))
    await started.wait()
    task.cancel()
    await asyncio.sleep(0)
    task.cancel()
    await asyncio.sleep(0)
    allow_spawn.set()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert process.terminated and not driver._folders


async def test_close_kills_stubborn_sender_even_with_repeated_cancellation(monkeypatch):
    process, driver = FakeProcess(ignore_term=True), ArcDriver()
    monkeypatch.setattr("litecu.arc.sys.platform", "darwin")
    monkeypatch.setattr("litecu.arc.asyncio.create_subprocess_exec", AsyncMock(return_value=process))
    task = asyncio.create_task(driver._run_script("fixed script"))
    await asyncio.sleep(0.02)
    task.cancel()
    await asyncio.sleep(0.02)
    await driver.close()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert process.terminated and process.killed and not driver._calls and not driver._folders


def test_existing_dom_regressions_against_python_assets(tmp_path):
    if not shutil.which("node"):
        pytest.skip("Node is needed for the fake DOM checks")
    key, token = "__litecu_test", "observation-one"
    text = 'A quote: "; a newline:\n; code-like text: ); globalThis.injected = true; //'
    def script(name, **arguments):
        return page_script("arc_action.js", {"key": key, "token": token, "name": name, "arguments": arguments})
    fixtures = {
        "snapshot": page_script("arc_snapshot.js", {"key": key, "token": token}),
        "next_snapshot": page_script("arc_snapshot.js", {"key": key, "token": "observation-two"}),
        "click": script("browser_click", element_id=token + ":0"),
        "missing_click": script("browser_click", element_id=token + ":99"),
        "type": script("browser_type", element_id=token + ":0", text=text),
        "scroll": script("browser_scroll", direction="down", amount=2),
        "unsupported": script("shell", element_id=token + ":0"), "expected_text": text,
    }
    path = tmp_path / "fixtures.json"
    path.write_text(json.dumps(fixtures))
    test_script = Path(__file__).resolve().parents[1] / "ArcDOM" / "arc-dom.test.cjs"
    result = subprocess.run(["node", str(test_script), str(path)], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "31 Arc DOM checks passed" in result.stdout


def test_native_script_syntax_without_running_arc(tmp_path):
    if sys.platform != "darwin" or not Path("/Applications/Arc.app").exists():
        pytest.skip("Compile-only Arc dictionary check requires macOS with Arc installed")
    scripts = [creation_script('https://example.com/?q="quoted"'), target_script("window", "tab"),
               navigation_script("window", "tab", "https://example.com"),
               evaluation_script("window", "tab", page_script("arc_snapshot.js", {"key": "key", "token": "token"}))]
    for index, script in enumerate(scripts):
        assert "exists window" not in script and "exists tab" not in script
        assert "set taskWindow" not in script and "set taskTab" not in script
        assert "front window" not in script and "active tab" not in script
        source = tmp_path / f"syntax-{index}.applescript"
        source.write_text(bridge_script(script))
        result = subprocess.run(["/usr/bin/osacompile", "-l", "AppleScript", "-o", str(source.with_suffix(".scpt")), str(source)],
                                capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, result.stderr


def test_applescript_string_escaping_and_fixed_asset_selection():
    assert apple_literal('"\\\n\r\t') == '"\\"\\\\\\n\\r\\t"'
    with pytest.raises(ValueError, match="Unknown fixed"):
        page_script("../../other.js", {})
