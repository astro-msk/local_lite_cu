"""Small, versioned UI preferences and history; never touches Swift history."""
from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile

DEFAULTS = {
    "model": "gpt-6.1-sol", "target": "auto", "approval": "every",
    "demo": True, "theme": "light", "speak": True, "max_steps": 12,
    "idle_seconds": 2.0, "show_hud": True,
}


class UIStore:
    def __init__(self, directory: Path | None = None):
        self.directory = directory or Path.home() / "Library/Application Support/local.litecu.app/python"

    def _load(self, name: str, default):
        path = self.directory / name
        if not path.exists():
            return default
        value = json.loads(path.read_text())
        if value.get("version") != 1:
            raise ValueError(f"Unsupported {name} version. The existing file was preserved.")
        return value["data"]

    def _save(self, name: str, data):
        # Do not overwrite unreadable data when a new run finishes.
        self._load(name, None)
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd, temporary = tempfile.mkstemp(prefix=".litecu-", dir=self.directory)
        try:
            with os.fdopen(fd, "w") as output:
                json.dump({"version": 1, "data": data}, output, ensure_ascii=False, indent=2)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, self.directory / name)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def settings(self) -> dict:
        saved = self._load("settings-v1.json", {})
        if not isinstance(saved, dict):
            raise ValueError("Settings are unreadable. The existing file was preserved.")
        values = DEFAULTS | {key: value for key, value in saved.items() if key in DEFAULTS}
        for key, choices in {"model": ("gpt-6.1-sol", "gpt-6-sol"), "target": ("auto", "desktop", "arc"),
                             "approval": ("every", "sensitive", "full"), "theme": ("light", "dark")}.items():
            if values[key] not in choices:
                values[key] = DEFAULTS[key]
        values["max_steps"] = max(1, min(30, int(values["max_steps"])))
        values["idle_seconds"] = max(0.5, min(10.0, float(values["idle_seconds"])))
        return values

    def save_settings(self, settings: dict):
        self._save("settings-v1.json", settings)

    def history(self) -> list[dict]:
        history = self._load("runs-v1.json", [])
        if not isinstance(history, list) or any(not isinstance(run, dict) for run in history):
            raise ValueError("Previous runs are unreadable. The existing file was preserved.")
        return history

    def save_run(self, run: dict) -> list[dict]:
        history = [run] + [entry for entry in self.history() if entry.get("id") != run["id"]]
        history = history[:100]
        self._save("runs-v1.json", history)
        return history
