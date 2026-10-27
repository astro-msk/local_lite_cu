#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -x .venv/bin/python ]]; then
  echo 'Create the environment first: uv sync --extra dev'
  exit 1
fi
exec .venv/bin/python -m litecu "$@"
