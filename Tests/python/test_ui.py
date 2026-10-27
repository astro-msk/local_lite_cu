"""Offscreen UI checks: no native driver, network, speech or microphone access."""
import os
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import time
import pytest
from PySide6.QtWidgets import QApplication
from PySide6.QtCore import Qt
from litecu.ui import MainWindow
from litecu.ui_storage import DEFAULTS, UIStore


@pytest.fixture(scope="module")
def app():
    return QApplication.instance() or QApplication([])


def pump(app, condition, timeout=5):
    deadline = time.monotonic() + timeout
    while not condition() and time.monotonic() < deadline:
        app.processEvents(); time.sleep(0.01)
    app.processEvents()
    assert condition(), "The Qt operation did not finish before the deadline"


def test_demo_approval_history_and_read_only_command(app, tmp_path):
    store = UIStore(tmp_path)
    store.save_settings(DEFAULTS | {"show_hud": False, "speak": False})
    window = MainWindow(store)
    window.command.setPlainText("Enter 200 in Calculator")
    window.run_task()
    try:
        pump(app, lambda: window.pending is not None)
        assert window.pending["type"] == "approval"
        assert window.command.isReadOnly()
        window.respond("approve")
        pump(app, lambda: window.worker is None)
        saved = store.history()
        assert len(saved) == 1 and saved[0]["status"] == "complete"
        assert any(node["kind"] == "action" for node in saved[0]["nodes"])
        window.show_history()
        window.open_history_item(window.history_list.item(0))
        assert window.read_only and window.command.isReadOnly()
        assert not window.run_button.isEnabled()
        window.new_chat()
        assert not window.read_only and not window.command.toPlainText()
        assert window.settings["approval"] == "every"
    finally:
        window.stop()
        if window.worker: pump(app, lambda: window.worker is None)
        window.close()


def test_settings_preserve_approval_and_never_touch_swift_history(tmp_path):
    swift_history = tmp_path / "runs.json"
    swift_history.write_text("Swift history remains unchanged")
    store = UIStore(tmp_path / "python")
    store.save_settings(DEFAULTS | {"approval": "full", "target": "arc", "theme": "dark"})
    assert store.settings()["approval"] == "full"
    assert store.settings()["target"] == "arc"
    assert store.settings()["theme"] == "dark"
    assert swift_history.read_text() == "Swift history remains unchanged"


def test_unreadable_history_is_never_replaced(tmp_path):
    store = UIStore(tmp_path)
    bad = tmp_path / "runs-v1.json"
    bad.write_text("unreadable")
    with pytest.raises(ValueError): store.save_run({"id": "new"})
    assert bad.read_text() == "unreadable"


def test_reopen_restores_minimized_window_and_hud_stays_available(app, tmp_path):
    window = MainWindow(UIStore(tmp_path))
    window.setWindowState(Qt.WindowState.WindowMinimized)
    assert window.isMinimized()
    window.show_workspace()
    app.processEvents()
    assert not window.isMinimized()
    assert window.hud.windowTitle() == "Lite CU status"
    assert window.hud.testAttribute(Qt.WidgetAttribute.WA_MacAlwaysShowToolWindow)
    assert window.hud.testAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
    assert window.hud.windowFlags() & Qt.WindowType.WindowDoesNotAcceptFocus
    window.close()
