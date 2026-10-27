"""Explicit microphone capture, offline Whisper, and optional macOS speech.

No microphone is opened during import or construction. All callbacks may run on
worker threads; the UI bridges them to Qt signals.
"""
from __future__ import annotations

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import threading
import time
import wave

_TRIGGER = re.compile(r"\b(?:cu|c[.\s]+u\.?)\s+start(?:\s+execution)?\b[.!]?", re.I)
_SPOKEN_END = re.compile(r"\bsee\s+you\s+start(?:\s+execution)?\b[.!?,;:\s]*$", re.I)
_speech_lock = threading.Lock()
_speech_process: subprocess.Popen | None = None


def parse_voice_command(text: str) -> tuple[str, bool]:
    """Only call for final transcripts. An empty task never executes."""
    if not _TRIGGER.search(text) and not _SPOKEN_END.search(text):
        return text.strip(), False
    command = re.sub(r"\s+", " ", _SPOKEN_END.sub(" ", _TRIGGER.sub(" ", text))).strip(" \n\t.,;:!?—–-")
    return command, bool(command)


def resolve_answer(text: str, options: list[str]) -> str:
    cleaned = text.strip().rstrip(".?!").casefold()
    numbers = {"one": 0, "two": 1, "three": 2, "four": 3, "first": 0, "second": 1, "third": 2, "fourth": 3}
    candidate = re.sub(r"^(?:option|number|the)\s+", "", cleaned)
    index = numbers.get(candidate)
    if candidate.isdigit():
        index = int(candidate) - 1
    if index is not None and 0 <= index < len(options):
        return options[index]
    return next((option for option in options if option.casefold() == cleaned), text.strip())


def stop_speaking():
    global _speech_process
    with _speech_lock:
        if _speech_process is not None and _speech_process.poll() is None:
            _speech_process.terminate()
        _speech_process = None


def speak(text: str):
    """Speak fixed question text, without passing it through a shell."""
    global _speech_process
    stop_speaking()
    if not Path("/usr/bin/say").exists():
        return
    with _speech_lock:
        _speech_process = subprocess.Popen(["/usr/bin/say", "--", text[:2400]], stdin=subprocess.DEVNULL,
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def whisper_configuration() -> tuple[str, Path]:
    executable = os.environ.get("LITECU_WHISPER_BIN") or shutil.which("whisper-cli")
    if not executable:
        executable = next((path for path in ("/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli")
                           if os.access(path, os.X_OK)), None)
    model = Path(os.environ.get("LITECU_WHISPER_MODEL", str(Path.home() / "Library/Application Support/LiteCU/Models/ggml-small.en.bin"))).expanduser()
    if not executable:
        raise RuntimeError("Install whisper.cpp with Homebrew before using voice.")
    if not model.is_file():
        raise RuntimeError("Whisper small.en is missing. Run scripts/setup-whisper.sh first.")
    return executable, model


class VoiceController:
    def __init__(self, on_state, on_text):
        self.on_state, self.on_text = on_state, on_text
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._cancel = threading.Event()
        self._process: subprocess.Popen | None = None

    @property
    def busy(self):
        return self._thread is not None and self._thread.is_alive()

    def start(self):
        with self._lock:
            if self.busy:
                return
            self._stop = threading.Event()
            self._cancel = threading.Event()
            self._thread = threading.Thread(target=self._capture, name="LiteCU Voice", daemon=True)
            self._thread.start()

    def stop(self):
        self._stop.set()

    def cancel(self):
        self._cancel.set()
        self._stop.set()
        with self._lock:
            if self._process is not None and self._process.poll() is None:
                self._process.terminate()

    def _state(self, state: str, detail: str, level=0.0):
        if not self._cancel.is_set() or state == "idle":
            self.on_state({"state": state, "detail": detail, "level": level})

    def _capture(self):
        text = ""
        try:
            self._state("starting", "Preparing microphone · offline Whisper")
            executable, model = whisper_configuration()
            import numpy as np
            import sounddevice as sd

            started = last_sound = time.monotonic()
            voiced = 0.0
            frames = []
            sample_rate = int(sd.query_devices(kind="input")["default_samplerate"])
            block_size = max(160, sample_rate // 10)
            with sd.InputStream(samplerate=sample_rate, channels=1, dtype="int16", blocksize=block_size) as stream:
                self._state("listening", "Listening · pause to transcribe, or click Stop recording")
                while not self._stop.is_set() and not self._cancel.is_set():
                    chunk, overflow = stream.read(block_size)
                    if overflow:
                        raise RuntimeError("Microphone audio was interrupted. Try dictating again.")
                    frames.append(chunk.copy())
                    rms = float(np.sqrt(np.mean((chunk.astype(np.float32) / 32768) ** 2)))
                    now = time.monotonic()
                    if rms > 0.008:
                        voiced += len(chunk) / sample_rate
                        last_sound = now
                    self._state("listening", "Listening · pause to transcribe", min(1, rms * 8))
                    if now - started >= 60 or (voiced >= 0.3 and now - last_sound >= 2):
                        break
            if self._cancel.is_set():
                return
            if not frames or voiced < 0.1:
                raise RuntimeError("No clear speech was detected. Check your microphone and try again.")
            self._state("transcribing", "Whisper is transcribing on this Mac…")
            with tempfile.TemporaryDirectory(prefix="litecu-voice-") as directory:
                recording, output = Path(directory) / "audio.wav", Path(directory) / "transcript"
                samples = np.concatenate(frames).reshape(-1)
                if sample_rate != 16_000:
                    positions = np.arange(int(len(samples) * 16_000 / sample_rate)) * sample_rate / 16_000
                    samples = np.interp(positions, np.arange(len(samples)), samples).clip(-32768, 32767).astype(np.int16)
                with wave.open(str(recording), "wb") as wav:
                    wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(16_000)
                    wav.writeframes(samples.tobytes())
                with self._lock:
                    if self._cancel.is_set():
                        return
                    self._process = subprocess.Popen([executable, "-m", str(model), "-f", str(recording),
                                                       "-l", "en", "-t", "4", "-nt", "-np", "-sns", "-otxt", "-of", str(output)],
                                                      stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    process = self._process
                deadline = time.monotonic() + 120
                while process.poll() is None:
                    if self._cancel.is_set() or time.monotonic() > deadline:
                        process.terminate()
                        try: process.wait(timeout=0.5)
                        except subprocess.TimeoutExpired:
                            process.kill(); process.wait()
                        if self._cancel.is_set(): return
                        raise RuntimeError("Whisper took too long. Try a shorter recording.")
                    time.sleep(0.05)
                if self._cancel.is_set(): return
                if process.returncode:
                    raise RuntimeError(f"Whisper could not transcribe this recording (exit {process.returncode}).")
                text = " ".join(output.with_suffix(".txt").read_text().split())
                if text.casefold() in ("[blank_audio]", "[silence]", "[music]", "(music)", "[no speech]"):
                    text = ""
                if not text:
                    raise RuntimeError("No words were recognized. Try speaking closer to the microphone.")
        except Exception as error:
            self._state("error", str(error))
        finally:
            with self._lock:
                self._process = None
            self._state("idle", "Whisper small.en · on this Mac")
        if text and not self._cancel.is_set():
            self.on_text(text)
