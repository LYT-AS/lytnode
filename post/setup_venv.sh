#!/bin/bash
# Sets up the Python environment for the post skill, in venv/ beside this file.
#
# Needs python3 with its venv module, and the network once, to fetch the one
# package post uses (PyYAML, see requirements.txt). Says "ready" only when both
# steps worked, and exits non-zero otherwise, so a caller can tell.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "Setting up post venv in $SCRIPT_DIR..."

if ! command -v python3 >/dev/null 2>&1; then
    echo "post venv: python3 is not installed; install it and run this again" >&2
    exit 1
fi
if ! python3 -m venv --help >/dev/null 2>&1; then
    echo "post venv: python3 has no venv module (on Debian and Ubuntu: the" >&2
    echo "python3-venv package); install it and run this again" >&2
    exit 1
fi

python3 -m venv "$SCRIPT_DIR/venv"
echo "  fetching PyYAML from the Python package index; without network this step"
echo "  fails, and post's hooks run on the system python3 until you run this again"
if ! "$SCRIPT_DIR/venv/bin/pip" install --quiet --upgrade pip \
        || ! "$SCRIPT_DIR/venv/bin/pip" install --quiet -r "$SCRIPT_DIR/requirements.txt"; then
    echo "post venv: could not install the requirements; run this again when online" >&2
    exit 1
fi
echo "✅ Post venv ready"
