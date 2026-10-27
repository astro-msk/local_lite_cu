# Build from the repository root with scripts/build-python-app.sh.
import os
from pathlib import Path
from PyInstaller.utils.hooks import collect_data_files

root = Path(SPECPATH).parent
identity = os.environ.get("LITECU_SIGNING_IDENTITY") or None
analysis = Analysis(
    [str(root / "packaging/launcher.py")],
    pathex=[str(root)],
    binaries=[],
    datas=collect_data_files("litecu"),
    hiddenimports=["AppKit", "Foundation", "Quartz", "ApplicationServices", "ScreenCaptureKit", "CoreMedia", "objc", "sounddevice", "numpy"],
    hookspath=[], hooksconfig={}, runtime_hooks=[],
    excludes=["tkinter", "PySide6.QtQml", "PySide6.QtQuick", "PySide6.QtWebEngineCore", "pytest"],
    noarchive=False,
)
pyz = PYZ(analysis.pure)
exe = EXE(pyz, analysis.scripts, [], exclude_binaries=True, name="LiteCU", debug=False,
          bootloader_ignore_signals=False, strip=False, upx=False, console=False,
          codesign_identity=identity, entitlements_file=str(root / "packaging/entitlements.plist"))
collection = COLLECT(exe, analysis.binaries, analysis.datas, strip=False, upx=False, name="LiteCU")
app = BUNDLE(collection, name="Lite CU.app", icon=str(root / "Resources/AppIcon.icns"),
             bundle_identifier="local.litecu.app", info_plist={
                 "CFBundleName": "Lite CU", "CFBundleDisplayName": "Lite CU",
                 "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "2",
                 "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
                 "NSMicrophoneUsageDescription": "Lite CU records your command only when you start dictation. Whisper transcribes it locally.",
                 "NSAppleEventsUsageDescription": "Lite CU controls its own Arc task tab when Background Arc is selected.",
             })
