# splitMusic

Script to separate music stems using Demucs with a quality-first setup.

## Requirements
- Python 3.11 or 3.10
- ffmpeg

## Installation
The script creates a venv in `.venv` and installs the packages from
`requirements.txt` on first run.

## Quick usage
```bash
./split.sh "path/to/file.m4a"
```

## Options
```bash
./split.sh [-m model] [-M vocals_model] [-o output_dir] [-f format] [-b bitrate] \
  [-k] [-d device] [-v venv_dir] [-q best|fast] <input_file>
```

## Quality
- `best` (default): uses `htdemucs_6s` for all stems and `htdemucs_ft` for vocals.
- `fast`: fewer shifts and overlap (faster, lower quality).

## Output
Stems are saved in `separated/<song-name>` in the chosen format.

## Example
```bash
./split.sh -q best -f mp3 -b 192k "song.wav"
```
