"""Display coordinates and interruption bookkeeping, independent of macOS APIs.

ScreenCaptureKit produces pixels; Quartz accepts points in the global desktop
coordinate system. Each display owns its transform, so Retina scale, a negative
origin, and windows spanning two monitors need no special-case input logic.
"""
from __future__ import annotations

from dataclasses import dataclass
import math
import threading
import time


@dataclass(frozen=True)
class DisplayGeometry:
    display_id: int
    x: float
    y: float
    width: float
    height: float
    image_width: int
    image_height: int
    pixel_width: int = 0
    pixel_height: int = 0

    def __post_init__(self):
        numbers = (self.x, self.y, self.width, self.height, self.image_width, self.image_height)
        if any(not isinstance(n, (int, float)) or isinstance(n, bool) or not math.isfinite(n) for n in numbers):
            raise ValueError("Display geometry must contain finite numbers.")
        if min(self.width, self.height, self.image_width, self.image_height) <= 0:
            raise ValueError("Display and screenshot dimensions must be positive.")

    def point(self, x: float, y: float) -> tuple[float, float]:
        """Map screenshot pixels to Quartz global points, rejecting outside edges."""
        if any(isinstance(n, bool) or not isinstance(n, (int, float)) or not math.isfinite(n) for n in (x, y)):
            raise ValueError("Coordinates must be finite numbers.")
        if not 0 <= x < self.image_width or not 0 <= y < self.image_height:
            raise ValueError("Coordinates are outside this display's screenshot.")
        return self.x + x * self.width / self.image_width, self.y + y * self.height / self.image_height

    @property
    def signature(self) -> tuple:
        """Changing resolution/scale counts even if logical display bounds stay put."""
        return self.display_id, self.x, self.y, self.width, self.height, self.pixel_width, self.pixel_height

    def description(self) -> str:
        return (f"display_id={self.display_id}: image {self.image_width}×{self.image_height} pixels; "
                f"global bounds ({self.x:g}, {self.y:g}, {self.width:g}, {self.height:g}) points")


def topology(displays: list[DisplayGeometry]) -> tuple:
    ids = [d.display_id for d in displays]
    if len(set(ids)) != len(ids):
        raise ValueError("Display identifiers must be unique.")
    return tuple(sorted(d.signature for d in displays))


class ActivityTracker:
    """Store only activity timestamps/counters, never typed keys or pointer paths."""
    def __init__(self, own_event_tag: int, clock=time.monotonic):
        self.own_event_tag = own_event_tag
        self._clock = clock
        self._lock = threading.Lock()
        self._last = 0.0
        self._generation = 0
        self._interaction_generation = 0

    def record(self, event_tag: int, meaningful=True) -> bool:
        if event_tag == self.own_event_tag:
            return False
        with self._lock:
            self._last = self._clock()
            self._generation += 1
            if meaningful:
                self._interaction_generation += 1
        return True

    @property
    def state(self) -> tuple[float, int]:
        with self._lock:
            return self._last, self._generation

    def changed(self, generation: int) -> bool:
        return self.state[1] != generation

    @property
    def interaction_generation(self) -> int:
        with self._lock:
            return self._interaction_generation

    @property
    def review_state(self) -> tuple[int, int]:
        with self._lock:
            return self._generation, self._interaction_generation
