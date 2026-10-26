#!/bin/bash
# One-time local dependency setup. The app never downloads or uploads voice audio.
set -euo pipefail

whisper_brew="$(command -v brew || true)"
if [[ -z "$whisper_brew" ]]; then
  echo "Install Homebrew first: https://brew.sh" >&2
  exit 1
fi
if [[ ! -x /opt/homebrew/bin/whisper-cli && ! -x /usr/local/bin/whisper-cli ]]; then
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 "$whisper_brew" install whisper.cpp
fi

whisper_model_dir="$HOME/Library/Application Support/LiteCU/Models"
whisper_model="$whisper_model_dir/ggml-small.en.bin"
whisper_sha="c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"
mkdir -p "$whisper_model_dir"
if [[ -f "$whisper_model" ]] && [[ "$(shasum -a 256 "$whisper_model" | cut -d ' ' -f 1)" == "$whisper_sha" ]]; then
  echo "Whisper small.en is ready. Audio stays on this Mac."
  exit 0
fi

whisper_partial="$(mktemp "$whisper_model_dir/.small.en.XXXXXX")"
trap 'rm -f "$whisper_partial"' EXIT
curl --fail --location --retry 3 --output "$whisper_partial" \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin
if [[ "$(shasum -a 256 "$whisper_partial" | cut -d ' ' -f 1)" != "$whisper_sha" ]]; then
  echo "Model checksum did not match. The downloaded file will be removed." >&2
  exit 1
fi
mv "$whisper_partial" "$whisper_model"
echo "Whisper small.en is ready. Audio stays on this Mac."
