#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == "--release" && -z "${LITECU_SIGNING_IDENTITY:-}" ]]; then
  echo 'Release builds require LITECU_SIGNING_IDENTITY. Ad-hoc signing cannot preserve permission identity across updates.' >&2
  exit 1
fi
if [[ -z "${LITECU_SIGNING_IDENTITY:-}" ]]; then
  echo 'Development build: ad-hoc signing. Permissions may need granting again after rebuilding.' >&2
fi
.venv/bin/python -m PyInstaller --noconfirm --distpath dist/python --workpath build/python packaging/LiteCU.spec
codesign --verify --deep --strict 'dist/python/Lite CU.app'
echo "Built $(pwd)/dist/python/Lite CU.app"
