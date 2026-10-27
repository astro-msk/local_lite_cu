# Python migration — October 27, 2026

The new application is implemented in Python. The working Swift app is retained as a reference; no changes to its existing permissions or installation are needed to inspect the Python code or run Demo.

## Implementation choices

- **PySide6 Essentials** provides the workspace and floating status panel. It keeps the code readable and avoids a web server, but bundles a larger runtime than SwiftUI.
- **PyObjC** calls native macOS frameworks for capture, input, and app activation. Platform details are isolated from the Python loop.
- **CodexModel** ports the restricted, model-only CLI adapter. The app keeps all action execution, approvals, state, and recovery.
- **One decision call** supplies the plan and next action. Optional parallel advisory calls from the Swift prototype are not enabled in this fast path.
- **Grouped input** permits up to six deterministic typing/key steps. Whole numbers are a single `type_text` action. Focus-changing keys and submissions end a group; coordinate clicks and navigation cannot be batched.
- **Interruption recovery** discards the rest of a pending group and takes a new observation after idle. It records completed inputs, so the next decision can adapt to the changed screen.
- **All displays** are separate images with explicit IDs and transforms. No assumption is made about screen order, origin, or scale.
- **Questions are separate from approval.** Even Full access waits for missing intent. Spoken questions use local macOS speech; answering by voice starts only after an explicit microphone action.

## Evidence so far

- Real GPT-6.1 Sol request through the Python Codex adapter passed using existing ChatGPT sign-in and the complete structured decision schema.
- Real GPT-6.1 Sol synthetic vision test correctly read two separate display images: display 11 / 217, display 29 / 843. No actual desktop content was used in this test.
- Deterministic tests verify routing, grouped input boundaries, rejected approvals, low-confidence questions, interruption during model work, interruption during a group, stale observations, and cancellation.
- Packaged app launched successfully in light and dark themes. Demo, approval review, history, Cmd+K, Cmd+N, and Cmd+Return were exercised through the UI.
- Live GPT-6.1 Sol / Python harness test completed `200 - 134` in native Calculator and verified `66`. An independent inspection of Calculator confirmed the result. The expression and Return were dispatched as one approved group, with no model call between digits. The run took 91 seconds, including approximately 43 seconds of approval waiting; grouped dispatch took less than a second.
- The live driver captured both connected displays (including the portrait display with a negative origin). This establishes multi-display observation, not yet successful coordinate clicking on both displays.
- The floating panel was visible during the live run, showing planning, approval, and input-interruption states. The first run reobserved after input; a controlled physical-interruption/resume test remains outstanding.
- Live Auto routing selected Background Arc for `https://example.com`, opened a dedicated task tab, and read the title `Example Domain` while the Lite CU workspace remained available. This Python run completed in 32 seconds, including 13 seconds waiting for approval.
- The first live test exposed early app-launch observation and terminal failure on a rejected input group. The driver now waits for foreground/window readiness; invalid groups receive bounded model feedback and a fresh observation. These fixes have regression tests and need confirmation in the final packaged build.
- A stable signing identity is not installed on this development Mac. The release script requires one; ad-hoc development builds are clearly labeled.

The user chose to keep development builds. Accessibility, Screen Recording, and Input Monitoring were explicitly granted and verified Allowed for the live test; a subsequent ad-hoc rebuild lost those grants. Permission preservation across updates is therefore **not solved on this Mac** until a stable signing identity is configured.

Native coordinate input on both monitors, the floating panel on multiple displays, controlled physical-interruption recovery, and voice execution still need live verification in the final packaged Python app. Synthetic tests do not establish those behaviors on this machine. Microphone permissions may also need refresh for the migrated bundle.

## Research references

- [HeyClicky](https://www.heyclicky.com/): compact voice-first desktop companion and on-screen help. Inspiration for the persistent, unobtrusive status surface.
- [OpenClicky](https://github.com/prasanthsasikumar/openclicky): open-source macOS screen guidance, local dictation, and agent handoff.
- [LocalClicky](https://github.com/tanavc1/LocalClicky): local inference exploration.
- [Cua](https://github.com/trycua/cua): broader computer-use drivers and testing infrastructure.
- [PyObjC](https://pyobjc.readthedocs.io/en/latest/): Python bindings to native macOS frameworks.
- [Apple TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html): identity, designated requirements, and code signing.
- [PyInstaller](https://www.pyinstaller.org/en/latest/man/pyinstaller.html): standalone packaging and identity-based signing.

No source code or artwork from these apps was copied into Lite CU.
