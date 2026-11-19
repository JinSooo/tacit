#!/bin/sh
# Build a local QNN-capable AAR from pinned official artifacts; never fetch speech models here.
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 "$base/scripts/prepare-speech.py"
