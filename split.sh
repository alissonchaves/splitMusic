#!/bin/bash

# ============================================================
# MUSIC STEM SEPARATION SCRIPT FOR APPLE SILICON (M4)
# ============================================================
# Purpose:
# - Separate stems from a fully mixed/mastered song
# - Use the best available Demucs model
# - Automatically leverage Apple GPU via MPS
# - Keep the pipeline clean and reproducible
# ============================================================

# === CONFIGURATION ===
MODEL_NAME="htdemucs_6s"
VOCALS_MODEL="htdemucs_ft"
INPUT_FILE=""
OUTPUT_DIR="separated"
OUTPUT_FORMAT="mp3"
BITRATE="192k"
KEEP_WAVS="false"
DEVICE_OVERRIDE=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${VENV_DIR:-$SCRIPT_DIR/.venv}"
REQUIREMENTS_FILE="$SCRIPT_DIR/requirements.txt"
QUALITY_MODE="best"
SHIFTS="8"
OVERLAP="0.75"

# === OPTIONS ===
while getopts ":m:M:o:f:b:kd:v:q:" opt; do
  case "$opt" in
    m) MODEL_NAME="$OPTARG" ;;
    M) VOCALS_MODEL="$OPTARG" ;;
    o) OUTPUT_DIR="$OPTARG" ;;
    f) OUTPUT_FORMAT="$OPTARG" ;;
    b) BITRATE="$OPTARG" ;;
    k) KEEP_WAVS="true" ;;
    d) DEVICE_OVERRIDE="$OPTARG" ;;
    v) VENV_DIR="$OPTARG" ;;
    q) QUALITY_MODE="$OPTARG" ;;
    *)
      echo "Usage: $0 [-m model] [-M vocals_model] [-o output_dir] [-f format] [-b bitrate] [-k] [-d device] [-v venv_dir] [-q best|fast] <input_file>"
      exit 1
      ;;
  esac
done
shift $((OPTIND - 1))
INPUT_FILE="${1:-}"

# === VALIDATION ===
set -euo pipefail
if [ -z "$INPUT_FILE" ]; then
  echo "ERROR: Please provide an input audio file."
  echo "Example:"
  echo "$0 -m htdemucs_6s -f mp3 'song.wav'"
  exit 1
fi

if [ ! -f "$INPUT_FILE" ]; then
  echo "ERROR: Input file does not exist."
  exit 1
fi

# === DEPENDENCY CHECKS ===
PYTHON_BIN=""
if command -v python3.11 >/dev/null 2>&1; then
  PYTHON_BIN="python3.11"
elif command -v python3.10 >/dev/null 2>&1; then
  PYTHON_BIN="python3.10"
elif command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
else
  echo "ERROR: python3.11, python3.10, python3, or python is required."
  exit 1
fi
command -v ffmpeg >/dev/null 2>&1 || { echo "ERROR: ffmpeg is required."; exit 1; }
command -v tree >/dev/null 2>&1 || { echo "WARN: tree not found; will use ls instead."; }

# === PYTHON VENV + REQUIREMENTS ===
if [ ! -d "$VENV_DIR" ]; then
  echo "Creating venv at: $VENV_DIR"
  $PYTHON_BIN -m venv "$VENV_DIR"
fi

if [ ! -x "$VENV_DIR/bin/python" ]; then
  echo "ERROR: venv python not found at: $VENV_DIR/bin/python"
  exit 1
fi

VENV_PYTHON="$VENV_DIR/bin/python"

# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"

if [ ! -f "$REQUIREMENTS_FILE" ]; then
  echo "ERROR: requirements.txt not found at: $REQUIREMENTS_FILE"
  exit 1
fi

echo "Installing Python requirements..."
$VENV_PYTHON -m pip install -r "$REQUIREMENTS_FILE"

$VENV_PYTHON - <<EOF
missing = []
requirements_path = "$REQUIREMENTS_FILE"
with open(requirements_path, "r", encoding="utf-8") as fh:
    reqs = [line.split("==", 1)[0].strip() for line in fh if line.strip() and not line.startswith("#")]

for pkg in reqs:
    try:
        __import__(pkg)
    except Exception:
        missing.append(pkg)

if missing:
    raise SystemExit("ERROR: Missing Python packages: " + ", ".join(missing))
EOF

# === DEVICE DETECTION (MPS OR CPU) ===
DEVICE="cpu"

if [ -n "$DEVICE_OVERRIDE" ]; then
  DEVICE="$DEVICE_OVERRIDE"
else
  DEVICE=$($VENV_PYTHON - <<'EOF'
import torch
if torch.backends.mps.is_available():
    print("mps")
else:
    print("cpu")
EOF
)
fi

echo "Selected compute backend: $DEVICE"

if [ "$QUALITY_MODE" = "fast" ]; then
  SHIFTS="2"
  OVERLAP="0.5"
fi

# === RUN DEMUCS ===
run_demucs() {
  local model="$1"
  echo "Starting stem separation using model '$model'..."
  $VENV_PYTHON -m demucs.separate \
    --device "$DEVICE" \
    --shifts "$SHIFTS" \
    --overlap "$OVERLAP" \
    -n "$model" \
    -o "$OUTPUT_DIR" \
    "$INPUT_FILE"
}

if [ "$QUALITY_MODE" = "best" ]; then
  run_demucs "$MODEL_NAME"
  if [ "$VOCALS_MODEL" != "$MODEL_NAME" ]; then
    run_demucs "$VOCALS_MODEL"
  fi
else
  run_demucs "$MODEL_NAME"
fi

# === PATH HANDLING ===
BASENAME=$(basename "$INPUT_FILE" | sed 's/\.[^.]*$//')
FINAL_DIR="$OUTPUT_DIR/$BASENAME"
PRIMARY_DIR="$OUTPUT_DIR/$MODEL_NAME/$BASENAME"
VOCALS_DIR="$OUTPUT_DIR/$VOCALS_MODEL/$BASENAME"

if [ -d "$FINAL_DIR" ] && [ "$(ls -A "$FINAL_DIR" 2>/dev/null || true)" != "" ]; then
  echo "ERROR: Destination already exists and is not empty: $FINAL_DIR"
  exit 1
fi

mkdir -p "$FINAL_DIR"

if [ -d "$PRIMARY_DIR" ]; then
  shopt -s nullglob
  for stem_path in "$PRIMARY_DIR"/*.wav; do
    cp -f "$stem_path" "$FINAL_DIR/"
  done
  shopt -u nullglob
fi

if [ "$QUALITY_MODE" = "best" ] && [ -f "$VOCALS_DIR/vocals.wav" ]; then
  cp -f "$VOCALS_DIR/vocals.wav" "$FINAL_DIR/"
fi

if [ -d "$OUTPUT_DIR/$MODEL_NAME" ]; then
  rm -rf "$OUTPUT_DIR/$MODEL_NAME"
fi
if [ -d "$OUTPUT_DIR/$VOCALS_MODEL" ] && [ "$VOCALS_MODEL" != "$MODEL_NAME" ]; then
  rm -rf "$OUTPUT_DIR/$VOCALS_MODEL"
fi

# === CONVERT STEMS ===
echo "Converting WAV stems to $OUTPUT_FORMAT..."

shopt -s nullglob
for stem_path in "$FINAL_DIR"/*.wav; do
  stem_file=$(basename "$stem_path")
  stem_name="${stem_file%.wav}"
  output_path="$FINAL_DIR/$stem_name.$OUTPUT_FORMAT"

  if [ "$OUTPUT_FORMAT" = "mp3" ]; then
    ffmpeg -y -loglevel error \
      -i "$stem_path" \
      -codec:a libmp3lame \
      -b:a "$BITRATE" \
      "$output_path"
  else
    ffmpeg -y -loglevel error \
      -i "$stem_path" \
      "$output_path"
  fi
done
shopt -u nullglob

# === OPTIONAL CLEANUP ===
if [ "$KEEP_WAVS" = "false" ]; then
  echo "Removing intermediate WAV files..."
  rm -f "$FINAL_DIR"/*.wav
fi

# === FINAL REPORT ===
echo "Stem separation completed successfully."
echo "Final directory structure:"
if command -v tree >/dev/null 2>&1; then
  tree "$FINAL_DIR"
else
  ls -1 "$FINAL_DIR"
fi
