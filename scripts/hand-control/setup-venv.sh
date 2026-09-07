#!/usr/bin/env bash
# setup-venv.sh — create the hand-control Python venv. Run this once, by hand.
#
# Installs into $XDG_DATA_HOME/hand-control/venv (NOT system site-packages).
# To undo: rm -rf that directory. ~170 MB of wheels, ~500 MB installed
# (mediapipe + opencv-contrib-python + numpy + matplotlib). No emerge, no root.
set -euo pipefail

DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/hand-control"
VENV="$DATA_DIR/venv"
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
MODEL_URL="https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/latest/hand_landmarker.task"
MODEL_DST="$DATA_DIR/hand_landmarker.task"

echo "hand-control venv  ->  $VENV"
mkdir -p "$DATA_DIR"

if [ ! -d "$VENV" ]; then
    python3 -m venv "$VENV"
fi
"$VENV/bin/pip" install --upgrade pip wheel
"$VENV/bin/pip" install -r "$HERE/requirements.txt"

echo
echo "installed:"
"$VENV/bin/pip" list 2>/dev/null | grep -iE "mediapipe|opencv|numpy" || true

# The Tasks API model (used if present; the legacy solutions API needs nothing).
if [ ! -f "$MODEL_DST" ]; then
    echo
    echo "fetching hand_landmarker.task (~7 MB) ..."
    curl -fL --create-dirs -o "$MODEL_DST" "$MODEL_URL" \
        && echo "  -> $MODEL_DST" \
        || echo "  (download failed — the legacy mediapipe.solutions API will be used instead)"
fi

# seed the user config so the runtime never silently falls back to defaults
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/hand-control/config.toml"
if [ ! -f "$CFG" ]; then
    mkdir -p "$(dirname "$CFG")"
    cp "$HERE/config.toml.example" "$CFG"
    echo "wrote $CFG"
else
    echo "kept existing $CFG"
fi

echo
echo "done. Try:  hand-control debug"
