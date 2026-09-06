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
readonly DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
readonly ICONS="$DATA/icons/hicolor"
readonly APPS="$DATA/applications"
# Reverse-DNS: icon lookup truncates at dashes, so "cpu-hog-watch"
# falls back to "cpu" and picks up the theme's own chip icon.
readonly APP_ID="io.github.im007.cpu-hog-watch"

say() { printf '  %s\n' "$*"; }

verify() {
    local rc=0
    printf '\ncpu-hog-watch verification\n'
    for f in "$BIN/cpu-hog-watch" "$BIN/cpu-hog-notify" \
             "$BIN/cpu-hog-lib.sh"; do
        if [ -x "$f" ]; then say "OK   $f"
        else say "FAIL $f"; rc=1; fi
    done
    if [ -r "$ICONS/scalable/apps/$APP_ID.svg" ]; then
        say "OK   $ICONS/scalable/apps/$APP_ID.svg"
    else
        say "WARN icon not installed - notifications fall back to a stock icon"
    fi
    if [ -r "$APPS/$APP_ID.desktop" ]; then
        say "OK   $APPS/$APP_ID.desktop"
    else
        say "WARN desktop entry missing - notifications may lose the icon"
    fi
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
    local sens
    sens="$("$BIN/cpu-hog-watch" --status 2>/dev/null | grep 'sensors ')"
    case "$sens" in
        *"NONE FOUND"*)
            say "WARN no thermal sensors - backstop cannot fire"
            say "     the per-process watcher is unaffected"
            say "     run 'cpu-hog-watch --detect' for detail" ;;
        *PARTIAL*)
            say "WARN only one thermal sensor found"
            say "     run 'cpu-hog-watch --detect' for detail" ;;
        *)
            say "OK  ${sens# *sensors     : }" ;;
    esac
    printf '\n'
    systemctl --user list-timers cpu-hog-watch.timer \
        --no-pager 2>/dev/null | head -3
    return "$rc"
}

uninstall() {
    systemctl --user disable --now cpu-hog-watch.timer 2>/dev/null || true
    rm -f "$UNITS/cpu-hog-watch.service" "$UNITS/cpu-hog-watch.timer"
    rm -f "$BIN/cpu-hog-watch" "$BIN/cpu-hog-notify" \
          "$BIN/cpu-hog-lib.sh"
    rm -f "$ICONS/scalable/apps/$APP_ID.svg" "$APPS/$APP_ID.desktop" \
          "$ICONS/scalable/apps/cpu-hog-watch.svg" \
          "$APPS/cpu-hog-watch.desktop"
    for sz in 16 32 48 64 128 256 512; do
        rm -f "$ICONS/${sz}x${sz}/apps/$APP_ID.png" \
              "$ICONS/${sz}x${sz}/apps/cpu-hog-watch.png"
    done
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
# Both scripts source the library from their own directory, so it has
# to sit alongside them in $BIN, not only in the clone.
ln -sfn "$SRC/cpu-hog-lib.sh" "$BIN/cpu-hog-lib.sh"
say "linked binaries into $BIN"

if [ ! -e "$ENVF" ]; then
    cp "$SRC/cpu-hog-watch.env.example" "$ENVF"
    say "created $ENVF"
else
    say "kept existing $ENVF"
fi

# Icon and desktop entry. The entry is NoDisplay - this is a background
# timer, not something to launch - but it gives the notification daemon a
# .desktop to bind the popup to, which is what keeps the icon and the app
# name attached once notifications are grouped.
install -d "$ICONS/scalable/apps" "$APPS"
install -m 644 "$SRC/assets/mark-amber.svg" \
        "$ICONS/scalable/apps/$APP_ID.svg"
for sz in 16 32 48 64 128 256 512; do
    [ -r "$SRC/assets/icon-$sz.png" ] || continue
    install -d "$ICONS/${sz}x${sz}/apps"
    install -m 644 "$SRC/assets/icon-$sz.png" \
            "$ICONS/${sz}x${sz}/apps/$APP_ID.png"
done
install -m 644 "$SRC/$APP_ID.desktop" "$APPS/$APP_ID.desktop"
# Sweep the pre-rename files so an upgrade does not leave a second,
# shadowed entry behind.
rm -f "$APPS/cpu-hog-watch.desktop" \
      "$ICONS/scalable/apps/cpu-hog-watch.svg"
for sz in 16 32 48 64 128 256 512; do
    rm -f "$ICONS/${sz}x${sz}/apps/cpu-hog-watch.png"
done
# Best-effort: the caches are an optimisation, and a stale one only delays
# the icon appearing. Never fail the install over them.
command -v gtk-update-icon-cache >/dev/null 2>&1 \
    && gtk-update-icon-cache -qtf "$ICONS" 2>/dev/null || true
command -v update-desktop-database >/dev/null 2>&1 \
    && update-desktop-database -q "$APPS" 2>/dev/null || true
# KDE keeps its own service cache and will not see a new .desktop until this
# runs. Without it the notification header falls back to a generic icon even
# though the file is in place.
command -v kbuildsycoca6 >/dev/null 2>&1 \
    && kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
say "installed icon and desktop entry"

install -m 644 "$SRC/cpu-hog-watch.service" "$UNITS/cpu-hog-watch.service"
install -m 644 "$SRC/cpu-hog-watch.timer"   "$UNITS/cpu-hog-watch.timer"
say "installed user units"

systemctl --user daemon-reload
systemctl --user enable --now cpu-hog-watch.timer
say "timer enabled and started"

verify
