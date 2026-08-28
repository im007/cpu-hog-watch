#!/usr/bin/env bash
#
# cpu-hog-watch - alerts when one process saturates a CPU core
# Copyright (C) 2026  im007
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version. This program comes
# with ABSOLUTELY NO WARRANTY. See the LICENSE file for the full text.
# Script: install.sh
# Purpose: Install cpu-hog-watch as a systemd USER timer.
# Prerequisites: systemd user session, libnotify
# Usage: ./install.sh [--uninstall] [--verify]
#
# Exit Codes:
#   0 - Success
#   1 - General error
#   3 - Missing dependencies
#
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
readonly SRC
readonly BIN="$HOME/.local/bin"
readonly UNITS="$HOME/.config/systemd/user"
readonly ENVF="$HOME/.config/cpu-hog-watch.env"

say() { printf '  %s\n' "$*"; }

verify() {
    local rc=0
    printf '\ncpu-hog-watch verification\n'
    for f in "$BIN/cpu-hog-watch" "$BIN/cpu-hog-notify"; do
        if [ -x "$f" ]; then say "OK   $f"
        else say "FAIL $f"; rc=1; fi
    done
    if [ -r "$ENVF" ]; then say "OK   $ENVF"
    else say "WARN $ENVF (defaults in use)"; fi
    if systemctl --user is-enabled cpu-hog-watch.timer >/dev/null 2>&1; then
        say "OK   timer enabled"
    else
        say "FAIL timer not enabled"; rc=1
    fi
    if systemctl --user is-active cpu-hog-watch.timer >/dev/null 2>&1; then
        say "OK   timer active"
    else
        say "FAIL timer not active"; rc=1
    fi
    command -v notify-send >/dev/null 2>&1 \
        && say "OK   notify-send present" \
        || { say "FAIL notify-send missing"; rc=1; }
    # The thermal backstop reads named hwmon sensors. If this host has
    # neither, it can never fire - say so at install time rather than
    # letting someone believe they have a safety net they do not.
    if "$BIN/cpu-hog-watch" --status 2>/dev/null | grep -q "INACTIVE"; then
        say "WARN thermal backstop INACTIVE - sensors not found"
        say "     the per-process watcher is unaffected"
        say "     run 'cpu-hog-watch --status' for what to set"
    else
        say "OK   thermal backstop has sensors"
    fi
    printf '\n'
    systemctl --user list-timers cpu-hog-watch.timer \
        --no-pager 2>/dev/null | head -3
    return "$rc"
}

uninstall() {
    systemctl --user disable --now cpu-hog-watch.timer 2>/dev/null || true
    rm -f "$UNITS/cpu-hog-watch.service" "$UNITS/cpu-hog-watch.timer"
    rm -f "$BIN/cpu-hog-watch" "$BIN/cpu-hog-notify"
    systemctl --user daemon-reload
    say "removed (config left at $ENVF)"
    exit 0
}

case "${1:-}" in
    --uninstall) uninstall ;;
    --verify)    verify; exit $? ;;
esac

command -v notify-send >/dev/null 2>&1 || {
    echo "notify-send missing: sudo dnf install libnotify" >&2; exit 3; }

mkdir -p "$BIN" "$UNITS"

# Symlink rather than copy so a git pull updates the live tool.
ln -sfn "$SRC/cpu-hog-watch"  "$BIN/cpu-hog-watch"
ln -sfn "$SRC/cpu-hog-notify" "$BIN/cpu-hog-notify"
say "linked binaries into $BIN"

if [ ! -e "$ENVF" ]; then
    cp "$SRC/cpu-hog-watch.env.example" "$ENVF"
    say "created $ENVF"
else
    say "kept existing $ENVF"
fi

install -m 644 "$SRC/cpu-hog-watch.service" "$UNITS/cpu-hog-watch.service"
install -m 644 "$SRC/cpu-hog-watch.timer"   "$UNITS/cpu-hog-watch.timer"
say "installed user units"

systemctl --user daemon-reload
systemctl --user enable --now cpu-hog-watch.timer
say "timer enabled and started"

verify
