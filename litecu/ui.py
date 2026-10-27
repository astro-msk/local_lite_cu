"""Qt presentation layer. Engine work and local transcription never block Qt.

The UI owns preferences, history, and human answers. Only the engine's drivers
control apps. Importing or opening this module does not request desktop access.
"""
from __future__ import annotations

import asyncio
from datetime import datetime, timezone
import inspect
import json
from pathlib import Path
import sys
import threading
import time
import uuid

from PySide6.QtCore import QEasingCurve, QEvent, QObject, QPoint, QPropertyAnimation, QThread, QTimer, Qt, QUrl, Signal
from PySide6.QtGui import QCloseEvent, QDesktopServices, QIcon, QKeySequence, QShortcut
from PySide6.QtWidgets import (
    QApplication, QButtonGroup, QCheckBox, QComboBox, QDialog, QDialogButtonBox,
    QDoubleSpinBox, QFormLayout, QFrame, QHBoxLayout, QLabel, QLineEdit,
    QListWidget, QListWidgetItem, QMainWindow, QMessageBox, QPushButton,
    QProgressBar, QRadioButton, QScrollArea, QSizePolicy, QSpinBox,
    QStackedWidget, QTextEdit, QVBoxLayout, QWidget,
)

from .ui_storage import DEFAULTS, UIStore
from .voice import VoiceController, parse_voice_command, resolve_answer, speak, stop_speaking

TARGETS = [("Auto · choose the right app", "auto"), ("Desktop", "desktop"), ("Background Arc", "arc")]
APPROVALS = [("Ask every action", "every"), ("Ask for sensitive actions", "sensitive"), ("Approve all · Full access", "full")]
APPROVAL_COPY = {
    "every": "Review each change before it runs. Observations and waits continue automatically.",
    "sensitive": "Review actions flagged as sensitive. Other supported actions run automatically.",
    "full": "Supported actions run automatically. Questions, macOS permissions, and action limits still apply.",
}


def duration(seconds: float | None) -> str:
    if seconds is None:
        return "—"
    seconds = max(0, int(seconds))
    if seconds < 60: return f"{seconds}s"
    if seconds < 3600: return f"{seconds // 60}m {seconds % 60:02d}s"
    return f"{seconds // 3600}h {(seconds % 3600) // 60:02d}m"


def label(text="", role="", wrap=False):
    widget = QLabel(text)
    widget.setTextFormat(Qt.TextFormat.PlainText)
    widget.setWordWrap(wrap)
    if role: widget.setObjectName(role)
    return widget


def button(text, callback, tone="neutral"):
    widget = QPushButton(text)
    widget.setProperty("tone", tone)
    widget.setCursor(Qt.CursorShape.PointingHandCursor)
    widget.clicked.connect(callback)
    widget.setMinimumHeight(34)
    return widget


def combo(items, selected):
    widget = QComboBox()
    for title, value in items: widget.addItem(title, value)
    widget.setCurrentIndex(max(0, widget.findData(selected)))
    widget.setMinimumHeight(32)
    return widget


def theme_styles(dark=False):
    background, panel, elevated, text, muted, line = (
        ("#121916", "#1c2520", "#29352e", "#edf3ee", "#adbbb0", "#3a4a40") if dark else
        ("#f8faf8", "#ffffff", "#eef3ef", "#23352a", "#64776b", "#dae5dd")
    )
    return f"""
        QWidget {{ color: {text}; font-family: -apple-system, 'Helvetica Neue', sans-serif; font-size: 13px; }}
        QMainWindow, QDialog, QWidget#page {{ background: {background}; }}
        QFrame#card, QFrame#nodeCard, QFrame#hud {{ background: {panel}; border: 1px solid {line}; border-radius: 12px; }}
        QFrame#nodeCard[active="true"] {{ border: 1px solid #3a7ad7; }}
        QFrame#pending {{ background: {panel}; border: 2px solid #d7ad35; border-radius: 12px; }}
        QLabel {{ background: transparent; }}
        QLabel#brand {{ font-size: 23px; font-weight: 650; }}
        QLabel#brandMark {{ background: #ccec70; color: #17261c; border-radius: 10px; font-size: 24px; font-weight: 700; }}
        QLabel#heading {{ font-size: 21px; font-weight: 650; }}
        QLabel#nodeTitle {{ font-size: 14px; font-weight: 600; }}
        QLabel#muted, QLabel#rail {{ color: {muted}; font-size: 12px; }}
        QLabel#eyebrow {{ color: {muted}; font-size: 10px; font-weight: 600; letter-spacing: 1px; }}
        QLabel#error {{ color: {'#ffa5a5' if dark else '#b12b36'}; padding: 9px; }}
        QLabel#status {{ color: {'#9ac2ff' if dark else '#1b60bd'}; font-weight: 600; }}
        QPushButton {{ background: {elevated}; border: 1px solid transparent; border-radius: 7px; padding: 6px 13px; font-weight: 600; }}
        QPushButton:hover {{ border-color: {muted}; }}
        QPushButton:focus {{ border: 2px solid #4e91ee; }}
        QPushButton:disabled {{ background: {elevated}; color: {muted}; border-color: transparent; }}
        QPushButton[tone="blue"] {{ background: #2468d1; color: white; }}
        QPushButton[tone="green"] {{ background: #27834a; color: white; }}
        QPushButton[tone="red"] {{ background: #c83441; color: white; }}
        QPushButton[tone="yellow"] {{ background: #f3d05b; color: #382d0c; }}
        QPushButton:checked {{ background: {text}; color: {panel}; }}
        QLineEdit, QTextEdit, QComboBox, QSpinBox, QDoubleSpinBox, QListWidget {{ background: {panel}; color: {text}; border: 1px solid {line}; border-radius: 7px; padding: 7px; selection-background-color: #2468d1; }}
        QTextEdit#command {{ border: none; font-size: 15px; padding: 2px; }}
        QComboBox {{ padding-right: 20px; }}
        QComboBox QAbstractItemView {{ background: {panel}; color: {text}; selection-background-color: #2468d1; }}
        QScrollArea {{ border: none; background: transparent; }}
        QScrollBar:vertical {{ background: transparent; width: 8px; }}
        QScrollBar::handle:vertical {{ background: {line}; border-radius: 4px; min-height: 30px; }}
        QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {{ height: 0; }}
        QProgressBar {{ background: {elevated}; border: none; border-radius: 3px; height: 6px; }}
        QProgressBar::chunk {{ background: #27834a; border-radius: 3px; }}
        QListWidget::item {{ padding: 14px; border-bottom: 1px solid {line}; }}
        QListWidget::item:selected {{ background: {elevated}; color: {text}; }}
        QCheckBox, QRadioButton {{ spacing: 7px; padding: 3px; }}
    """


class Bridge(QObject):
    voice_state = Signal(dict)
    voice_text = Signal(str)
    diagnostic = Signal(str)


class LazyDriver:
    """No native driver is constructed until a live run actually needs it."""
    def __init__(self, target):
        self.target, self.value = target, None

    def _get(self):
        if self.value is None:
            if self.target == "arc":
                from .arc import ArcDriver
                self.value = ArcDriver()
            else:
                from .desktop import DesktopDriver
                self.value = DesktopDriver()
        return self.value

    @property
    def instructions(self): return self._get().instructions
    @property
    def user_activity(self): return getattr(self.value, "user_activity", 0.0)
    @property
    def activity_generation(self): return getattr(self.value, "activity_generation", 0)

    def set_stop_handler(self, callback):
        driver = self._get()
        if hasattr(driver, "set_stop_handler"): driver.set_stop_handler(callback)

    def accept_review(self):
        driver = self._get()
        if hasattr(driver, "accept_review"): return driver.accept_review()

    def request_stop(self):
        if self.value is not None and hasattr(self.value, "request_stop"): self.value.request_stop()

    async def prepare(self):
        driver = self._get()
        if hasattr(driver, "prepare"):
            value = driver.prepare()
            if inspect.isawaitable(value): await value

    async def snapshot(self): return await self._get().snapshot()
    async def execute(self, action): return await self._get().execute(action)
    async def close(self):
        if self.value is not None and hasattr(self.value, "close"):
            value = self.value.close()
            if inspect.isawaitable(value): await value


class EngineWorker(QThread):
    event_received = Signal(dict)

    def __init__(self, command, settings, parent=None):
        super().__init__(parent)
        self.command, self.settings = command, dict(settings)
        self.engine = None
        self.cancel_requested = threading.Event()

    def stop(self):
        self.cancel_requested.set()
        if self.engine: self.engine.stop()

    def run(self):
        try: asyncio.run(self._run())
        except Exception as error:
            self.event_received.emit({"type": "result", "title": "Could not finish", "detail": str(error), "status": "failed"})

    async def _run(self):
        from .core import DemoDriver, DemoModel, Engine
        if self.settings["demo"]:
            model, drivers = DemoModel(), {"desktop": DemoDriver(), "arc": DemoDriver()}
            self.settings["target"] = "desktop"
        else:
            from .codex import CodexModel
            model = CodexModel(model=self.settings["model"])
            drivers = {target: LazyDriver(target) for target in ("desktop", "arc")}
        self.engine = Engine(model=model, drivers=drivers, emit=self.event_received.emit, settings=self.settings)
        if self.cancel_requested.is_set(): self.engine.stop()
        await self.engine.run(self.command)


class WorkflowRow(QWidget):
    def __init__(self, number: int, node: dict, parent=None):
        super().__init__(parent)
        self.node, self.changed = {}, time.monotonic()
        layout = QHBoxLayout(self); layout.setContentsMargins(0, 0, 0, 0); layout.setSpacing(14)
        rail = QWidget(); rail.setFixedWidth(94)
        rail_layout = QVBoxLayout(rail); rail_layout.setContentsMargins(0, 10, 0, 0); rail_layout.setSpacing(6)
        self.kind = label(f"{number:02d}", "rail")
        self.timer = label("", "rail")
        rail_layout.addWidget(self.kind); rail_layout.addWidget(self.timer); rail_layout.addStretch()
        layout.addWidget(rail)
        card = QFrame(); card.setObjectName("nodeCard"); self.card = card
        content = QVBoxLayout(card); content.setContentsMargins(17, 14, 17, 14); content.setSpacing(9)
        heading = QHBoxLayout()
        self.title = label("", "nodeTitle", True); self.state = label("", "muted")
        heading.addWidget(self.title, 1); heading.addWidget(self.state, 0, Qt.AlignmentFlag.AlignTop)
        content.addLayout(heading)
        self.detail = label("", wrap=True)
        self.detail.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        content.addWidget(self.detail)
        self.details_button = button("Show details", self.toggle_details)
        self.details_button.setMaximumWidth(130)
        content.addWidget(self.details_button)
        self.raw = QTextEdit(); self.raw.setReadOnly(True); self.raw.setMaximumHeight(145); self.raw.hide()
        content.addWidget(self.raw)
        layout.addWidget(card, 1)
        self.number = number
        self.update_node(node)

    def update_node(self, node):
        previous_status = self.node.get("status")
        self.node = dict(node)
        if previous_status != node.get("status"): self.changed = time.monotonic()
        kind = node.get("kind", "step").replace("_", " ").title()
        self.kind.setText(f"{self.number:02d}  {kind}")
        self.title.setText(str(node.get("title", kind)))
        status = str(node.get("status", "complete"))
        self.state.setText({"complete": "Done", "active": "In progress", "awaiting": "Your turn"}.get(status, status.title()))
        detail = str(node.get("detail", ""))
        is_long = len(detail) > 1000 or kind.lower() == "action"
        self.detail.setText(detail[:900] + "…" if len(detail) > 1000 else ("Inspect the exact action below." if kind.lower() == "action" and detail.startswith("{") else detail))
        self.raw.setPlainText(detail)
        self.details_button.setVisible(is_long)
        if not is_long: self.raw.hide()
        self.card.setProperty("active", status in ("active", "awaiting"))
        self.card.style().unpolish(self.card); self.card.style().polish(self.card)
        self.tick()

    def toggle_details(self):
        self.raw.setVisible(not self.raw.isVisible())
        self.details_button.setText("Hide details" if self.raw.isVisible() else "Show details")

    def tick(self):
        elapsed = self.node.get("elapsed")
        if self.node.get("status") in ("active", "awaiting"):
            elapsed = float(elapsed or 0) + time.monotonic() - self.changed
        self.timer.setText(duration(elapsed))
        self.timer.setToolTip("Elapsed wall time for this workflow step.")


class PendingCard(QFrame):
    def __init__(self, event, respond, voice, parent=None):
        super().__init__(parent)
        self.request, self.respond = event, respond
        self.setObjectName("pending")
        layout = QVBoxLayout(self); layout.setContentsMargins(18, 16, 18, 16); layout.setSpacing(11)
        layout.addWidget(label(event.get("title", "Your input"), "nodeTitle"))
        layout.addWidget(label(event.get("detail", ""), wrap=True))
        self.answer = QLineEdit(); self.answer.setPlaceholderText("Or write your own answer…")
        if event["type"] == "approval":
            exact = QTextEdit(); exact.setReadOnly(True); exact.setMaximumHeight(130)
            exact.setPlainText(json.dumps(event.get("actions", []), indent=2, ensure_ascii=False))
            layout.addWidget(exact)
            buttons = QHBoxLayout()
            buttons.addWidget(button("Reject & stop", lambda: respond("reject"), "red")); buttons.addStretch()
            buttons.addWidget(button("Approve step", lambda: respond("approve"), "yellow"))
            layout.addLayout(buttons)
        else:
            self.choices = QButtonGroup(self)
            for option in event.get("options", []):
                choice = QRadioButton(str(option)); self.choices.addButton(choice)
                choice.toggled.connect(lambda checked, value=str(option): self.answer.setText(value) if checked else None)
                layout.addWidget(choice)
            self.answer.setMaxLength(4000); layout.addWidget(self.answer)
            buttons = QHBoxLayout()
            buttons.addWidget(button("Cancel task", lambda: respond(None), "red"))
            self.voice_button = button("Answer by voice", voice, "green")
            buttons.addWidget(self.voice_button); buttons.addStretch()
            self.continue_button = button("Continue", lambda: respond(self.answer.text().strip()), "blue")
            self.continue_button.setEnabled(False)
            self.answer.textChanged.connect(lambda text: self.continue_button.setEnabled(bool(text.strip())))
            buttons.addWidget(self.continue_button); layout.addLayout(buttons)
            layout.addWidget(label("Voice starts only when you click. Your spoken answer continues this task.", "muted", True))


class RunHUD(QWidget):
    def __init__(self, show_main, pause, stop):
        super().__init__(None, Qt.WindowType.Tool | Qt.WindowType.FramelessWindowHint |
                         Qt.WindowType.WindowStaysOnTopHint | Qt.WindowType.WindowDoesNotAcceptFocus)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        self.setAttribute(Qt.WidgetAttribute.WA_MacAlwaysShowToolWindow)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setWindowTitle("Lite CU status")
        self.setAccessibleName("Lite CU run status")
        self.setFixedWidth(288)
        self.drag_offset = None
        self.fade = QPropertyAnimation(self, b"windowOpacity", self)
        self.fade.setDuration(160); self.fade.setEasingCurve(QEasingCurve.Type.OutCubic)
        outer = QVBoxLayout(self); outer.setContentsMargins(0, 0, 0, 0)
        frame = QFrame(); frame.setObjectName("hud"); outer.addWidget(frame)
        layout = QVBoxLayout(frame); layout.setContentsMargins(16, 15, 16, 15); layout.setSpacing(10)
        header = QHBoxLayout()
        self.drag_handle = label("⠿  lite cu", "nodeTitle")
        self.drag_handle.setCursor(Qt.CursorShape.OpenHandCursor)
        self.drag_handle.installEventFilter(self); header.addWidget(self.drag_handle); header.addStretch()
        self.elapsed = label("0s", "muted"); header.addWidget(self.elapsed); layout.addLayout(header)
        self.title = label("Getting ready", "status", True); layout.addWidget(self.title)
        self.detail = label("", "muted", True); layout.addWidget(self.detail)
        controls = QHBoxLayout()
        self.pause_button = button("Pause", pause); controls.addWidget(self.pause_button)
        controls.addWidget(button("Show", show_main)); controls.addWidget(button("Stop", stop, "red"))
        layout.addLayout(controls)

    def show_without_focus(self):
        from PySide6.QtGui import QCursor
        display = QApplication.screenAt(QCursor.pos()) or QApplication.primaryScreen()
        screen = display.availableGeometry()
        self.adjustSize(); self.move(screen.right() - self.width() - 22, screen.top() + 90)
        self.show()
        # Qt's no-focus flag is the primary behavior. Native flags keep it visible
        # across Spaces without making it a key window or changing the target app.
        if sys.platform == "darwin" and QApplication.platformName() != "offscreen":
            try:
                import objc
                from AppKit import NSFloatingWindowLevel
                view = objc.objc_object(c_void_p=int(self.winId()))
                window = view.window()
                window.setLevel_(NSFloatingWindowLevel)
                window.setCollectionBehavior_(1 | 256)
                if window.respondsToSelector_("setHidesOnDeactivate:"):
                    window.setHidesOnDeactivate_(False)
            except Exception:
                pass
        reduce_motion = False
        if sys.platform == "darwin":
            try:
                from AppKit import NSWorkspace
                reduce_motion = bool(NSWorkspace.sharedWorkspace().accessibilityDisplayShouldReduceMotion())
            except Exception: pass
        if not reduce_motion and QApplication.platformName() != "offscreen":
            self.fade.stop(); self.fade.setStartValue(0.0); self.fade.setEndValue(1.0); self.fade.start()

    def eventFilter(self, watched, event):
        if watched is self.drag_handle:
            if event.type() == QEvent.Type.MouseButtonPress and event.button() == Qt.MouseButton.LeftButton:
                self.drag_offset = event.globalPosition().toPoint() - self.frameGeometry().topLeft(); return True
            if event.type() == QEvent.Type.MouseMove and self.drag_offset is not None:
                self.move(event.globalPosition().toPoint() - self.drag_offset); return True
            if event.type() == QEvent.Type.MouseButtonRelease:
                self.drag_offset = None; return True
        return super().eventFilter(watched, event)

    def update_state(self, title, detail, elapsed, paused=False):
        self.title.setText(title); self.detail.setText(detail[:160])
        self.elapsed.setText(duration(elapsed)); self.pause_button.setText("Resume" if paused else "Pause")
        self.adjustSize()


class MainWindow(QMainWindow):
    def __init__(self, store: UIStore | None = None):
        super().__init__()
        self.store = store or UIStore()
        self.startup_errors = []
        try: self.settings = self.store.settings()
        except Exception as error:
            self.settings = dict(DEFAULTS); self.startup_errors.append(str(error))
        try: self.saved_runs = self.store.history()
        except Exception as error:
            self.saved_runs = []; self.startup_errors.append(str(error))
        self.worker = None
        self.nodes, self.rows = {}, {}
        self.current_run = None
        self.read_only = False
        self.pending = None
        self.pending_widget = None
        self.voice_state = "idle"
        self.voice_context = None
        self.active_target = self.settings["target"]
        self.started = None
        self.total_elapsed = 0.0
        self.status_title, self.status_detail = "Ready", "Type a task or use voice."
        self.paused = False
        self.quit_requested = False
        self.bridge = Bridge(self)
        self.bridge.voice_state.connect(self.on_voice_state)
        self.bridge.voice_text.connect(self.on_voice_text)
        self.voice = VoiceController(self.bridge.voice_state.emit, self.bridge.voice_text.emit)
        self.hud = RunHUD(self.show_workspace, self.toggle_pause, self.stop)
        self.setWindowTitle("Lite CU")
        self.setMinimumSize(1000, 700); self.resize(1160, 850)
        icon = Path(__file__).parent / "assets/AppIcon.icns"
        if icon.exists(): self.setWindowIcon(QIcon(str(icon)))
        self._build()
        self.apply_theme()
        self._shortcuts()
        self.timer = QTimer(self); self.timer.setInterval(500); self.timer.timeout.connect(self.tick); self.timer.start()
        self.update_controls()
        if self.startup_errors: self.notice.setText("\n".join(self.startup_errors)); self.notice.show()

    @property
    def running(self): return self.worker is not None and self.worker.isRunning()

    @property
    def voice_busy(self): return self.voice_state in ("starting", "listening", "transcribing")

    def _build(self):
        root = QWidget(); root.setObjectName("page"); self.setCentralWidget(root)
        outer = QVBoxLayout(root); outer.setContentsMargins(28, 20, 28, 18); outer.setSpacing(16)
        header = QHBoxLayout(); header.setSpacing(12)
        mark = label("↗", "brandMark"); mark.setAlignment(Qt.AlignmentFlag.AlignCenter); mark.setFixedSize(39, 39)
        header.addWidget(mark); header.addWidget(label("lite cu", "brand"))
        self.workspace_tab = button("Workspace", self.show_workspace)
        self.history_tab = button("Previous runs", self.show_history)
        for tab in (self.workspace_tab, self.history_tab): tab.setCheckable(True); header.addWidget(tab)
        self.workspace_tab.setChecked(True); header.addStretch()
        self.new_button = button("＋ New task", self.new_chat, "blue"); header.addWidget(self.new_button)
        header.addWidget(button("⌘ K", self.command_palette)); header.addWidget(button("Settings", self.open_settings))
        outer.addLayout(header)
        self.pages = QStackedWidget(); outer.addWidget(self.pages, 1)
        self.workspace = QWidget(); self.workspace.setObjectName("page")
        layout = QVBoxLayout(self.workspace); layout.setContentsMargins(0, 0, 0, 0); layout.setSpacing(13)
        strip = QFrame(); strip.setObjectName("card")
        strip_layout = QVBoxLayout(strip); strip_layout.setContentsMargins(16, 11, 16, 11); strip_layout.setSpacing(9)
        status = QHBoxLayout()
        self.status_label = label("●  Ready", "status"); status.addWidget(self.status_label)
        self.elapsed_label = label("", "muted"); status.addWidget(self.elapsed_label); status.addStretch()
        self.pause_button = button("Pause", self.toggle_pause); status.addWidget(self.pause_button)
        self.stop_button = button("Stop", self.stop, "red"); status.addWidget(self.stop_button)
        self.preview_button = button("Preview approval", self.preview_approval, "yellow"); status.addWidget(self.preview_button)
        strip_layout.addLayout(status)
        config = QHBoxLayout(); config.setSpacing(10)
        self.target_picker = combo(TARGETS, self.settings["target"]); self.target_picker.setMinimumWidth(205)
        self.approval_picker = combo(APPROVALS, self.settings["approval"]); self.approval_picker.setMinimumWidth(220)
        self.model_picker = combo([("GPT 6.1 Sol", "gpt-6.1-sol"), ("GPT 6 Sol", "gpt-6-sol")], self.settings["model"])
        self.mode_picker = combo([("Demo", True), ("Live", False)], self.settings["demo"])
        config.addWidget(label("Target", "muted")); config.addWidget(self.target_picker)
        config.addWidget(label("Approval", "muted")); config.addWidget(self.approval_picker)
        config.addStretch(); config.addWidget(self.model_picker); config.addWidget(self.mode_picker)
        strip_layout.addLayout(config)
        self.config_widgets = [self.target_picker, self.approval_picker, self.model_picker, self.mode_picker]
        for widget in self.config_widgets: widget.currentIndexChanged.connect(self.settings_changed)
        self.approval_hint = label(APPROVAL_COPY[self.settings["approval"]], "muted", True)
        strip_layout.addWidget(self.approval_hint); layout.addWidget(strip)
        self.strip = strip
        self.history_banner = label("Previous run · Read only. Start a new task to run again.", "status", True)
        self.history_banner.hide(); layout.addWidget(self.history_banner)
        self.scroll = QScrollArea(); self.scroll.setWidgetResizable(True)
        body = QWidget(); body.setObjectName("page"); self.body_layout = QVBoxLayout(body)
        self.body_layout.setContentsMargins(0, 0, 8, 12); self.body_layout.setSpacing(18)
        self.scroll.setWidget(body); layout.addWidget(self.scroll, 1)
        self.composer = QFrame(); self.composer.setObjectName("card")
        compose = QVBoxLayout(self.composer); compose.setContentsMargins(18, 14, 18, 14); compose.setSpacing(9)
        heading = QHBoxLayout(); heading.addWidget(label("YOUR TASK", "eyebrow")); heading.addStretch(); heading.addWidget(label("⌘ Return to run", "muted")); compose.addLayout(heading)
        self.command = QTextEdit(); self.command.setObjectName("command")
        self.command.setPlaceholderText("What would you like to do on your Mac?")
        self.command.setFixedHeight(96); self.command.textChanged.connect(self.update_controls); compose.addWidget(self.command)
        actions = QHBoxLayout()
        self.mic_button = button("● Voice", self.toggle_voice, "green"); actions.addWidget(self.mic_button)
        self.voice_meter = QProgressBar(); self.voice_meter.setRange(0, 100); self.voice_meter.setTextVisible(False); self.voice_meter.setFixedSize(65, 6)
        self.voice_meter.hide(); actions.addWidget(self.voice_meter)
        self.voice_label = label("Whisper small.en · on this Mac", "muted"); actions.addWidget(self.voice_label); actions.addStretch()
        self.run_button = button("Run demo  ↗", self.run_task, "blue"); actions.addWidget(self.run_button); compose.addLayout(actions)
        compose.addWidget(label("Say your task, then “CU start” to run. Otherwise, review the transcript first.", "muted", True))
        self.privacy = label("Demo is a fixed Calculator rehearsal. It does not control apps or send a model request.", "muted", True); compose.addWidget(self.privacy)
        self.body_layout.addWidget(self.composer)
        self.notice = label("", "error", True); self.notice.hide(); self.body_layout.addWidget(self.notice)
        self.pending_container = QWidget(); self.pending_layout = QVBoxLayout(self.pending_container)
        self.pending_layout.setContentsMargins(0, 0, 0, 0); self.pending_container.hide(); self.body_layout.addWidget(self.pending_container)
        self.examples = QWidget(); example_layout = QVBoxLayout(self.examples); example_layout.setContentsMargins(0, 0, 0, 0)
        example_layout.addWidget(label("Start with something small", "nodeTitle"))
        examples = QHBoxLayout()
        for title, command in [("Calculator · enter 200", "Open Calculator and enter 200"),
                               ("Read a website", "Open https://www.swift.org and summarize the latest news"),
                               ("Open Downloads", "Open Finder and show Downloads")]:
            examples.addWidget(button(title, lambda checked=False, text=command: self.command.setPlainText(text)))
        example_layout.addLayout(examples); example_layout.addWidget(label("Examples fill the task box. You decide when to run.", "muted")); self.body_layout.addWidget(self.examples)
        flow_header = QHBoxLayout(); flow_header.addWidget(label("Workflow", "heading")); flow_header.addStretch()
        self.follow = QCheckBox("Follow live"); self.follow.setChecked(True); flow_header.addWidget(self.follow); self.body_layout.addLayout(flow_header)
        self.graph = QWidget(); self.graph_layout = QVBoxLayout(self.graph)
        self.graph_layout.setContentsMargins(0, 0, 0, 0); self.graph_layout.setSpacing(13)
        self.body_layout.addWidget(self.graph)
        self.empty = label("Command  →  Plan  →  Action  →  Observation  →  Result\nEvery step will appear here as it happens.", "muted", True)
        self.graph_layout.addWidget(self.empty); self.body_layout.addStretch()
        self.pages.addWidget(self.workspace)
        self.history_page = QWidget(); self.history_page.setObjectName("page")
        history_layout = QVBoxLayout(self.history_page); history_layout.setContentsMargins(0, 8, 0, 0)
        history_layout.addWidget(label("Previous runs", "heading"))
        history_layout.addWidget(label("Saved on this Mac. Open a workflow without repeating any action.", "muted"))
        self.history_list = QListWidget(); self.history_list.itemActivated.connect(self.open_history_item)
        history_layout.addWidget(self.history_list, 1)
        self.history_error = label("", "error", True); self.history_error.hide(); history_layout.addWidget(self.history_error)
        history_layout.addWidget(button("Open selected run", lambda: self.open_history_item(self.history_list.currentItem()), "blue"), 0, Qt.AlignmentFlag.AlignRight)
        self.pages.addWidget(self.history_page)
        outer.addWidget(label("⌘ K commands   ·   ⌘ N new task   ·   ⌘ ⇧ Space voice   ·   ⌘ ⇧ Esc stop", "muted"))

    def _shortcuts(self):
        self.shortcuts = []
        for keys, callback in [("Ctrl+K", self.command_palette), ("Ctrl+N", self.new_chat),
                               ("Ctrl+Return", self.run_task), ("Ctrl+Shift+Escape", self.stop),
                               ("Ctrl+Shift+Space", self.toggle_voice), ("Ctrl+,", self.open_settings)]:
            shortcut = QShortcut(QKeySequence(keys), self)
            shortcut.setContext(Qt.ShortcutContext.ApplicationShortcut); shortcut.activated.connect(callback)
            self.shortcuts.append(shortcut)

    def apply_theme(self):
        QApplication.instance().setStyleSheet(theme_styles(self.settings["theme"] == "dark"))

    def persist_settings(self):
        try: self.store.save_settings(self.settings)
        except Exception as error: self.show_notice(str(error))

    def settings_changed(self):
        if self.running or self.read_only: return
        self.settings.update(target=self.target_picker.currentData(), approval=self.approval_picker.currentData(),
                             model=self.model_picker.currentData(), demo=self.mode_picker.currentData())
        self.approval_hint.setText(APPROVAL_COPY[self.settings["approval"]])
        self.privacy.setText("Demo is a fixed Calculator rehearsal. No app control or model request." if self.settings["demo"] else
                             "Live sends your task and observed screen/page content to OpenAI through your Codex sign-in.")
        self.persist_settings(); self.update_controls()

    def show_notice(self, text):
        self.notice.setText(text); self.notice.setVisible(bool(text))

    def update_controls(self):
        busy = self.running
        self.command.setReadOnly(busy or self.voice_busy or self.read_only)
        self.run_button.setEnabled(not busy and not self.voice_busy and not self.read_only and bool(self.command.toPlainText().strip()))
        self.run_button.setText("Run demo  ↗" if self.settings["demo"] else "Run task  ↗")
        self.new_button.setEnabled(not busy and not self.voice_busy)
        self.history_tab.setEnabled(not busy and not self.voice_busy)
        self.stop_button.setVisible(busy); self.pause_button.setVisible(busy); self.preview_button.setVisible(not busy)
        for widget in self.config_widgets: widget.setEnabled(not busy and not self.read_only and not self.voice_busy)
        self.mic_button.setEnabled(not self.read_only and not busy and self.voice_state not in ("starting", "transcribing"))
        self.examples.setVisible(not self.nodes and not busy and not self.read_only)
        self.strip.setVisible(not self.read_only); self.history_banner.setVisible(self.read_only)

    def clear_graph(self):
        for row in self.rows.values(): self.graph_layout.removeWidget(row); row.deleteLater()
        self.rows.clear(); self.nodes.clear(); self.empty.show()

    def new_chat(self):
        if self.running or self.voice_busy: return
        self.read_only = False; self.current_run = None; self.started = None; self.total_elapsed = 0
        self.clear_graph(); self.clear_pending(); self.command.clear(); self.show_notice("")
        self.status_title = "Ready"; self.status_detail = "Type a task or use voice."
        self.update_controls(); self.show_workspace(); self.scroll.verticalScrollBar().setValue(0); self.command.setFocus()

    def show_workspace(self):
        self.pages.setCurrentWidget(self.workspace); self.workspace_tab.setChecked(True); self.history_tab.setChecked(False)
        if self.isMinimized(): self.showNormal()
        else: self.show()
        self.raise_(); self.activateWindow()

    def show_history(self):
        if self.running or self.voice_busy: return
        self.pages.setCurrentWidget(self.history_page); self.workspace_tab.setChecked(False); self.history_tab.setChecked(True)
        self.history_list.clear()
        try: self.saved_runs = self.store.history(); self.history_error.hide()
        except Exception as error: self.history_error.setText(str(error)); self.history_error.show()
        for run in self.saved_runs:
            stamp = str(run.get("started_at", ""))[:16].replace("T", " · ")
            details = f"{stamp}   ·   {run.get('status', 'Finished').title()}   ·   {duration(run.get('elapsed'))}   ·   {'Demo' if run.get('settings', {}).get('demo') else 'Live'}"
            item = QListWidgetItem(str(run.get("command", "Untitled task"))[:140] + "\n" + details)
            item.setData(Qt.ItemDataRole.UserRole, run); self.history_list.addItem(item)
        if not self.saved_runs: self.history_error.setText("No saved Python runs yet. Your Swift prototype history remains untouched."); self.history_error.show()

    def open_history_item(self, item):
        if item is None or self.running or self.voice_busy: return
        run = item.data(Qt.ItemDataRole.UserRole)
        self.clear_graph(); self.read_only = True; self.current_run = run; self.started = None
        self.command.setPlainText(run.get("command", "")); self.total_elapsed = run.get("elapsed", 0)
        for node in run.get("nodes", []): self.add_node(node)
        saved = run.get("settings", {})
        self.history_banner.setText(f"Previous run · {run.get('started_at', '')[:16]} · {saved.get('model', '')} · {saved.get('target', '')} · {duration(run.get('elapsed'))}\nRead only. New task starts a fresh workspace.")
        self.clear_pending(); self.show_notice(""); self.update_controls(); self.show_workspace(); self.scroll.verticalScrollBar().setValue(0)

    def run_task(self):
        if self.running or self.voice_busy or self.read_only: return
        command = self.command.toPlainText().strip()
        if not command: self.command.setFocus(); return
        self.clear_graph(); self.clear_pending(); self.show_notice(""); self.follow.setChecked(True)
        self.started = time.monotonic(); self.total_elapsed = 0; self.paused = False
        self.status_title, self.status_detail = "Starting", "Preparing the task"
        settings = dict(self.settings)
        self.current_run = {"id": uuid.uuid4().hex, "command": command,
                            "started_at": datetime.now(timezone.utc).isoformat(), "settings": settings}
        self.worker = EngineWorker(command, settings, self); self.worker.event_received.connect(self.on_event)
        self.worker.finished.connect(self.worker_finished)
        if settings["show_hud"]: self.hud.show_without_focus()
        if not settings["demo"] and settings["target"] in ("auto", "desktop"): self.hide()
        self.worker.start(); self.update_controls()

    def on_event(self, event):
        kind = event.get("type")
        if event.get("target"): self.active_target = event["target"]
        if kind == "node":
            self.remove_live_node(); self.add_node(event)
        elif kind in ("status", "route"):
            self.status_title = event.get("title", self.status_title); self.status_detail = event.get("detail", "")
            if kind == "route":
                if not self.settings["demo"] and self.active_target == "desktop": self.hide()
            else:
                self.paused = self.status_title == "Paused" or self.paused and self.status_title == "You have control"
                if self.status_title in ("Resuming", "Acting", "Observing", "Planning", "Choosing next step"): self.paused = False
                self.add_node({"id": "_live", "kind": "planning" if "Planning" in self.status_title or "Choosing" in self.status_title else "progress",
                               "title": self.status_title, "detail": self.status_detail, "status": "active", "elapsed": 0})
        elif kind in ("approval", "question"):
            self.remove_live_node(); self.pending = dict(event); self.pending["token"] = uuid.uuid4().hex
            self.status_title = "Your approval" if kind == "approval" else "Your answer"
            self.status_detail = event.get("detail", "")
            self.set_pending(event)
            if not self.settings["show_hud"]: self.show_workspace()
            if kind == "question" and self.settings["speak"]:
                options = ". ".join(f"Option {index + 1}: {option}" for index, option in enumerate(event.get("options", [])))
                speak(event.get("detail", "") + ". " + options + ". Click Answer by voice to respond, or choose in the app.")
            # The HUD advertises the question; only Show or a shortcut activates the main window.
        elif kind == "result":
            self.remove_live_node(); self.clear_pending(); stop_speaking()
            for identity, node in list(self.nodes.items()):
                if node.get("status") in ("active", "awaiting"):
                    row = self.rows[identity]
                    final_node = node | {"status": event.get("status", "complete"),
                                         "elapsed": float(node.get("elapsed", 0)) + time.monotonic() - row.changed}
                    self.add_node(final_node)
            self.status_title, self.status_detail = event.get("title", "Finished"), event.get("detail", "")
            self.total_elapsed = float(event.get("elapsed", time.monotonic() - (self.started or time.monotonic())))
            self.started = None
            if event.get("status") == "failed": self.show_notice(self.status_detail)
            if self.current_run and "ended_at" not in self.current_run:
                self.current_run.update(ended_at=datetime.now(timezone.utc).isoformat(), status=event.get("status", "complete"),
                                        result=self.status_detail, elapsed=self.total_elapsed, nodes=list(self.nodes.values()))
                try: self.saved_runs = self.store.save_run(self.current_run)
                except Exception as error: self.show_notice(str(error))
            self.hud.hide()
            self.show_workspace()
        self.tick()

    def add_node(self, node):
        node = dict(node); identity = node.get("id") or uuid.uuid4().hex; node["id"] = identity
        if identity != "_live": self.nodes[identity] = node
        self.empty.hide()
        if identity in self.rows: self.rows[identity].update_node(node)
        else:
            row = WorkflowRow(len(self.nodes) + (1 if identity == "_live" else 0), node)
            self.rows[identity] = row; self.graph_layout.addWidget(row)
        if self.follow.isChecked() and not self.read_only:
            QTimer.singleShot(0, lambda: self.scroll.verticalScrollBar().setValue(self.scroll.verticalScrollBar().maximum()))

    def remove_live_node(self):
        row = self.rows.pop("_live", None)
        if row: self.graph_layout.removeWidget(row); row.deleteLater()

    def set_pending(self, event):
        if self.pending_widget: self.pending_widget.deleteLater()
        self.pending_widget = PendingCard(event, self.respond, lambda: self.toggle_voice(question=True))
        self.pending_layout.addWidget(self.pending_widget); self.pending_container.show()
        QTimer.singleShot(0, lambda: self.scroll.ensureWidgetVisible(self.pending_container))

    def clear_pending(self):
        if self.pending_widget:
            self.pending_layout.removeWidget(self.pending_widget); self.pending_widget.deleteLater()
        self.pending_widget = None; self.pending = None; self.pending_container.hide()

    def respond(self, value):
        if not self.pending or not self.worker or not self.worker.engine: return
        if value is None or value == "reject": self.stop(); return
        value = str(value).strip()
        if not value: return
        stop_speaking()
        if not self.settings["demo"] and self.active_target == "desktop": self.hide()
        self.worker.engine.respond(value); self.clear_pending()
        self.status_title, self.status_detail = "Continuing", "Refreshing the task context"

    def toggle_pause(self):
        if not self.running or not self.worker.engine: return
        self.paused = not self.paused
        if self.paused: self.worker.engine.pause(); self.status_title = "Pausing"
        else:
            if not self.settings["demo"] and self.active_target == "desktop": self.hide()
            self.worker.engine.resume(); self.status_title = "Resuming"
        self.tick()

    def stop(self):
        self.voice.cancel(); stop_speaking()
        if self.worker and self.worker.isRunning():
            self.worker.stop(); self.status_title = "Stopping"; self.status_detail = "Finishing cancellation. No new actions will start."
        self.clear_pending(); self.tick()

    def worker_finished(self):
        self.update_controls(); self.pause_button.setText("Pause"); self.hud.hide()
        if self.worker:
            self.worker.deleteLater(); self.worker = None
        self.update_controls()
        if self.quit_requested: QApplication.instance().quit()

    def tick(self):
        elapsed = time.monotonic() - self.started if self.started is not None else self.total_elapsed
        self.status_label.setText("●  " + self.status_title)
        self.elapsed_label.setText("Total " + duration(elapsed) if self.current_run else "")
        self.pause_button.setText("Resume" if self.paused else "Pause")
        self.hud.update_state(self.status_title, self.status_detail, elapsed, self.paused)
        for row in self.rows.values(): row.tick()

    def toggle_voice(self, question=False):
        if self.voice_state == "listening": self.voice.stop(); return
        if self.voice_busy or self.read_only: return
        if self.running:
            if not self.pending or self.pending["type"] != "question": return
            question = True
        stop_speaking(); self.show_notice("")
        self.voice_context = self.pending["token"] if question and self.pending else "command"
        self.voice_state = "starting"; self.update_controls(); self.voice.start()

    def on_voice_state(self, event):
        self.voice_state = event["state"]
        if event["state"] == "error": self.show_notice(event["detail"])
        self.voice_label.setText(event["detail"])
        self.mic_button.setText("Stop recording" if event["state"] == "listening" else "● Voice")
        self.voice_meter.setVisible(event["state"] == "listening"); self.voice_meter.setValue(int(event.get("level", 0) * 100))
        if self.pending_widget and hasattr(self.pending_widget, "voice_button"):
            self.pending_widget.voice_button.setText("Stop recording" if event["state"] == "listening" else "Answer by voice")
            self.pending_widget.voice_button.setEnabled(event["state"] not in ("starting", "transcribing"))
        self.update_controls()

    def on_voice_text(self, text):
        context = self.voice_context; self.voice_context = None
        if context != "command":
            if self.pending and context == self.pending.get("token"):
                answer = resolve_answer(text, self.pending.get("options", []))
                if answer.casefold().strip(".?!") in ("cancel task", "stop task"): self.stop()
                else: self.respond(answer)
            return
        if self.running or self.read_only: return
        command, execute = parse_voice_command(text)
        self.command.setPlainText(command)
        if execute: self.run_task()
        elif not command: self.show_notice("Say a task before “CU start”, or type one here.")

    def preview_approval(self):
        if self.running: return
        dialog = QDialog(self); dialog.setWindowTitle("Approval preview"); dialog.setMinimumWidth(540)
        layout = QVBoxLayout(dialog); layout.setContentsMargins(20, 20, 20, 20)
        layout.addWidget(label("Preview only · no action will run", "heading"))
        result = label("Choose a sample decision.", "muted", True)
        sample = {"type": "approval", "title": "Sample action", "detail": "Open Calculator in this isolated preview.",
                  "actions": [{"name": "open_app", "arguments": {"bundle_id": "com.apple.calculator"}}]}
        card = PendingCard(sample, lambda value: (result.setText(f"Sample {'approved' if value == 'approve' else 'rejected'}. No action was executed."), card.setEnabled(False)), lambda: None)
        layout.addWidget(card); layout.addWidget(result); layout.addWidget(button("Done", dialog.accept, "blue"), 0, Qt.AlignmentFlag.AlignRight)
        dialog.exec()

    def command_palette(self):
        dialog = QDialog(self); dialog.setWindowTitle("Commands"); dialog.setMinimumWidth(460)
        layout = QVBoxLayout(dialog); search = QLineEdit(); search.setPlaceholderText("Type a command…"); layout.addWidget(search)
        choices = QListWidget(); layout.addWidget(choices)
        actions = [("Focus task · ⌘ K", lambda: (self.show_workspace(), self.command.setFocus())),
                   ("New task · ⌘ N", self.new_chat), ("Run task · ⌘ Return", self.run_task),
                   ("Pause / resume", self.toggle_pause), ("Stop · ⌘ ⇧ Esc", self.stop),
                   ("Voice · ⌘ ⇧ Space", self.toggle_voice), ("Previous runs", self.show_history), ("Settings", self.open_settings)]
        def populate(text=""):
            choices.clear()
            for index, (title, _) in enumerate(actions):
                if text.casefold() in title.casefold():
                    item = QListWidgetItem(title); item.setData(Qt.ItemDataRole.UserRole, index); choices.addItem(item)
            choices.setCurrentRow(0)
        def choose(item):
            if item is not None:
                callback = actions[item.data(Qt.ItemDataRole.UserRole)][1]; dialog.accept(); callback()
        search.textChanged.connect(populate); search.returnPressed.connect(lambda: choose(choices.currentItem()))
        choices.itemActivated.connect(choose); populate(); dialog.resize(460, 350); search.setFocus(); dialog.exec()

    def open_settings(self):
        SettingsDialog(self).exec()

    def closeEvent(self, event: QCloseEvent):
        if self.running:
            self.hide(); event.ignore(); return
        self.voice.cancel(); stop_speaking(); self.hud.close(); event.accept()


class SettingsDialog(QDialog):
    def __init__(self, window: MainWindow):
        super().__init__(window)
        self.window = window; self.setWindowTitle("Settings"); self.setMinimumWidth(560)
        layout = QVBoxLayout(self); layout.setContentsMargins(22, 20, 22, 20); layout.setSpacing(15)
        layout.addWidget(label("Settings", "heading"))
        form = QFormLayout(); form.setSpacing(14)
        self.theme = combo([("Light", "light"), ("Dark", "dark")], window.settings["theme"])
        self.theme.currentIndexChanged.connect(self.change_theme); form.addRow("Appearance", self.theme)
        self.steps = QSpinBox(); self.steps.setRange(1, 30); self.steps.setValue(window.settings["max_steps"]); form.addRow("Action limit", self.steps)
        self.idle = QDoubleSpinBox(); self.idle.setRange(0.5, 10); self.idle.setSingleStep(0.5); self.idle.setSuffix(" seconds"); self.idle.setValue(window.settings["idle_seconds"]); form.addRow("Wait after your mouse / keyboard input", self.idle)
        self.speak = QCheckBox("Read clarification questions aloud"); self.speak.setChecked(window.settings["speak"]); form.addRow(self.speak)
        self.show_hud = QCheckBox("Show floating run HUD"); self.show_hud.setChecked(window.settings["show_hud"]); form.addRow(self.show_hud)
        for widget in (self.steps, self.idle, self.speak, self.show_hud): widget.setEnabled(not window.running)
        layout.addLayout(form)
        layout.addWidget(label("Model connection", "nodeTitle"))
        layout.addWidget(label("Uses your existing Codex sign-in. No API key is stored in this app.", "muted", True))
        self.connection = label("Choose Check connection to verify sign-in.", "muted", True); layout.addWidget(self.connection)
        self.check_button = button("Check connection", self.check_connection, "blue"); self.check_button.setEnabled(not window.running); layout.addWidget(self.check_button, 0, Qt.AlignmentFlag.AlignLeft)
        layout.addWidget(label("Mac access", "nodeTitle"))
        permissions = "Permission status is available on macOS."
        if sys.platform == "darwin":
            try:
                from .desktop import DesktopDriver
                state = DesktopDriver.permissions()
                permissions = "  ·  ".join(f"{key.replace('_', ' ').title()}: {'Allowed' if value else 'Needed'}" for key, value in state.items())
            except Exception: permissions = "Permission status could not be checked. Open System Settings to review access."
        layout.addWidget(label(permissions, "muted", True))
        access_buttons = QHBoxLayout()
        access_buttons.addWidget(button("Accessibility", lambda: QDesktopServices.openUrl(QUrl("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"))))
        access_buttons.addWidget(button("Screen Recording", lambda: QDesktopServices.openUrl(QUrl("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"))))
        access_buttons.addWidget(button("Microphone", lambda: QDesktopServices.openUrl(QUrl("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"))))
        layout.addLayout(access_buttons)
        layout.addWidget(button("Input Monitoring", lambda: QDesktopServices.openUrl(QUrl("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"))), 0, Qt.AlignmentFlag.AlignLeft)
        layout.addWidget(label("Desktop requires Accessibility, Screen Recording, and Input Monitoring to yield safely to your mouse and keyboard. Background Arc needs Automation and Arc → View → Developer → Allow JavaScript from Apple Events.", "muted", True))
        layout.addWidget(label("Voice uses the installed local Whisper model. Only an explicit click or voice shortcut starts microphone capture. Questions can be spoken aloud; capture never starts automatically.", "muted", True))
        layout.addWidget(label("Keyboard shortcuts work while Lite CU has focus. Desktop’s emergency stop is also available during live control when Accessibility permits it.", "muted", True))
        controls = QDialogButtonBox(QDialogButtonBox.StandardButton.Close); controls.rejected.connect(self.accept); layout.addWidget(controls)
        self.finished.connect(self.save)
        self.diagnostic_bridge = Bridge(self); self.diagnostic_bridge.diagnostic.connect(self.connection_result)

    def change_theme(self):
        self.window.settings["theme"] = self.theme.currentData(); self.window.apply_theme(); self.window.persist_settings()

    def save(self):
        if not self.window.running:
            self.window.settings.update(max_steps=self.steps.value(), idle_seconds=self.idle.value(),
                                        speak=self.speak.isChecked(), show_hud=self.show_hud.isChecked())
            self.window.persist_settings()

    def check_connection(self):
        self.check_button.setEnabled(False); self.connection.setText("Checking Codex sign-in…")
        model_name = self.window.settings["model"]
        signal = self.diagnostic_bridge.diagnostic
        def check():
            try:
                from .codex import CodexModel
                result = asyncio.run(CodexModel(model=model_name).status())
            except Exception as error: result = str(error)
            try: signal.emit(result)
            except RuntimeError: pass  # Dialog was closed during the diagnostic.
        threading.Thread(target=check, name="LiteCU Connection", daemon=True).start()

    def connection_result(self, result):
        self.connection.setText(result); self.check_button.setEnabled(True)


class LiteCUApplication(QApplication):
    window = None

    def restore_minimized_window(self):
        if self.window is not None and self.window.isMinimized():
            self.window.show_workspace()

    def event(self, event):
        if event.type() == QEvent.Type.ApplicationActivate:
            QTimer.singleShot(0, self.restore_minimized_window)
        if event.type() == QEvent.Type.Quit and self.window is not None and self.window.running:
            self.window.quit_requested = True
            self.window.stop()
            return True  # Keep Qt alive until the engine's cancellation cleanup finishes.
        return super().event(event)


def main():
    app = QApplication.instance() or LiteCUApplication(sys.argv)
    app.setApplicationName("Lite CU"); app.setOrganizationName("LiteCU")
    app.setStyle("Fusion")
    app.setQuitOnLastWindowClosed(True)
    window = MainWindow(); app.window = window; window.show()
    app.applicationStateChanged.connect(lambda state: app.restore_minimized_window()
                                        if state == Qt.ApplicationState.ApplicationActive and hasattr(app, "restore_minimized_window") else None)
    app.aboutToQuit.connect(window.stop)
    return app.exec()
