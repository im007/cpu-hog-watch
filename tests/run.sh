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
#
# Script: tests/run.sh
# Purpose: Regression tests for sensor discovery and for the read-only
#          commands. Every sensor is faked under a temp directory, so
#          the suite reads no real hardware and needs none.
# Prerequisites: bash 4+, coreutils. No test framework.
# Usage: tests/run.sh
#
# Exit Codes:
#   0 - Every test passed
#   1 - At least one test failed
#

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
readonly REPO
readonly WATCH="$REPO/cpu-hog-watch"
readonly LIB="$REPO/cpu-hog-lib.sh"

TMP="$(mktemp -d)" || { echo "cannot create a temp directory" >&2; exit 1; }
readonly TMP
trap '[ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"' EXIT

passed=0
failed=0

ok()   { passed=$(( passed + 1 )); printf 'ok    %s\n' "$1"; }
fail() { failed=$(( failed + 1 )); printf 'FAIL  %s\n      %s\n' "$1" "$2"; }

assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"
    else fail "$1" "expected '$3', got '$2'"; fi
}

assert_contains() {
    case "$2" in
        *"$3"*) ok "$1" ;;
        *) fail "$1" "expected to find '$3' in: $(printf '%s' "$2" | head -c 400)" ;;
    esac
}

assert_lacks() {
    case "$2" in
        *"$3"*) fail "$1" "did not expect '$3' in: $(printf '%s' "$2" | head -c 400)" ;;
        *) ok "$1" ;;
    esac
}

# A fresh fake /sys/class/hwmon. Prints its path.
new_root() {
    local r; r="$(mktemp -d "$TMP/hwmon.XXXXXX")"
    printf '%s\n' "$r"
}

# add_temp ROOT INDEX DRIVER [LABEL=MILLIDEGREES ...]
# An empty LABEL writes an input with no label file, which is how a
# single-temperature driver such as cpu_thermal looks.
add_temp() {
    local root="$1" idx="$2" drv="$3" d n=0 pair lbl val
    shift 3
    d="$root/hwmon$idx"
    mkdir -p "$d"
    printf '%s\n' "$drv" > "$d/name"
    for pair in "$@"; do
        n=$(( n + 1 ))
        lbl="${pair%%=*}"; val="${pair#*=}"
        [ -n "$lbl" ] && printf '%s\n' "$lbl" > "$d/temp${n}_label"
        printf '%s\n' "$val" > "$d/temp${n}_input"
    done
}

# add_fan ROOT INDEX DRIVER RPM...
add_fan() {
    local root="$1" idx="$2" drv="$3" d n=0 rpm
    shift 3
    d="$root/hwmon$idx"
    mkdir -p "$d"
    printf '%s\n' "$drv" > "$d/name"
    for rpm in "$@"; do
        n=$(( n + 1 ))
        printf '%s\n' "$rpm" > "$d/fan${n}_input"
    done
}

# Run one library function against a fake root, in a clean subshell.
# lib ROOT [VAR=VALUE ...] -- FUNCTION [ARGS...]
lib() {
    local root="$1"; shift
    (
        while [ "$1" != "--" ]; do export "${1?}"; shift; done
        shift
        export CPU_HOG_HWMON_ROOT="$root"
        # shellcheck source=../cpu-hog-lib.sh
        . "$LIB"
        "$@"
    )
}

# Run the watcher against a fake root with its own state directory.
# watch ROOT ENV_FILE [ARGS...]
watch() {
    local root="$1" envf="$2"; shift 2
    mkdir -p "$TMP/run" "$TMP/bin"
    # The sampling run refuses to start without notify-send. A stub
    # keeps the suite independent of what the host has installed, and
    # guarantees no test can raise a real notification.
    [ -x "$TMP/bin/notify-send" ] || {
        printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/notify-send"
        chmod +x "$TMP/bin/notify-send"
    }
    PATH="$TMP/bin:$PATH" XDG_RUNTIME_DIR="$TMP/run" \
        CPU_HOG_HWMON_ROOT="$root" CPU_HOG_ENV_FILE="$envf" \
        "$WATCH" "$@" 2>&1
}

# ---- temperature source: which device is read ------------------------------

# One k10temp per die: a Threadripper 2950X exposes two, and the first
# one enumerated is not necessarily the hotter.
r="$(new_root)"
add_temp "$r" 0 k10temp Tctl=63500 Tdie=36500
add_temp "$r" 1 k10temp Tctl=65600 Tdie=38600
assert_eq "hottest die is read when the cooler one enumerates first" \
    "$(lib "$r" -- _cpu_temp_c)" "38"

r="$(new_root)"
add_temp "$r" 0 k10temp Tctl=65600 Tdie=38600
add_temp "$r" 1 k10temp Tctl=63500 Tdie=36500
assert_eq "hottest die is read when it enumerates first" \
    "$(lib "$r" -- _cpu_temp_c)" "38"

r="$(new_root)"
add_temp "$r" 0 nvme Composite=45000
add_temp "$r" 1 k10temp Tctl=68000 Tdie=41000
assert_eq "a single device reads as before" \
    "$(lib "$r" -- _cpu_temp_c)" "41"

# Tdie outranks Tctl by probe order, not by magnitude: Tctl carries a
# fixed offset on these parts and always reads higher.
r="$(new_root)"
add_temp "$r" 0 k10temp Tctl=90000 Tdie=63000
assert_eq "Tdie is preferred over a numerically higher Tctl" \
    "$(lib "$r" -- _cpu_temp_c)" "63"

r="$(new_root)"
add_temp "$r" 0 k10temp Tctl=63500 Tdie=36500
add_temp "$r" 1 k10temp Tctl=65600 Tdie=38600
assert_eq "an explicit driver and label reads the hottest match" \
    "$(lib "$r" THERM_HWMON=k10temp THERM_LABEL=Tctl -- _cpu_temp_c)" "65"

r="$(new_root)"
add_temp "$r" 0 coretemp "Package id 0=52000" "Core 0=50000"
add_temp "$r" 1 coretemp "Package id 0=57000" "Core 0=55000"
assert_eq "dual-socket coretemp reads the hotter package" \
    "$(lib "$r" -- _cpu_temp_c)" "57"

r="$(new_root)"
add_temp "$r" 0 cpu_thermal =48000
assert_eq "a driver with one unlabelled temperature is read" \
    "$(lib "$r" -- _cpu_temp_c)" "48"

r="$(new_root)"
add_temp "$r" 0 acpitz_0 =44000
assert_eq "the generic ACPI probe matches by prefix" \
    "$(lib "$r" -- _cpu_temp_c)" "44"

# A sensor that reads empty must not win, and must not hide a good one.
r="$(new_root)"
add_temp "$r" 0 k10temp Tdie=
add_temp "$r" 1 k10temp Tdie=40000
assert_eq "an unreadable device is skipped for a readable one" \
    "$(lib "$r" -- _cpu_temp_c)" "40"

r="$(new_root)"
add_temp "$r" 0 nvme Composite=45000
if lib "$r" -- _cpu_temp_c >/dev/null 2>&1; then
    fail "no CPU sensor reports failure" "_cpu_temp_c succeeded with no CPU sensor"
else
    ok "no CPU sensor reports failure"
fi

r="$(new_root)"
add_temp "$r" 0 k10temp Tdie=36500
add_temp "$r" 1 k10temp Tdie=38600
assert_eq "the first matching device is still what a name lookup returns" \
    "$(lib "$r" -- _hwmon_by_name k10temp)" "$r/hwmon0"

# ---- fan source -------------------------------------------------------------

r="$(new_root)"
add_fan "$r" 0 amdgpu 0
add_fan "$r" 1 nct6779 931 1044 1501 0 981
assert_eq "the fastest fan across controllers is reported" \
    "$(lib "$r" -- _find_fan_source)" "1501|nct6779/fan3"

r="$(new_root)"
add_fan "$r" 0 amdgpu 1200
add_fan "$r" 1 nct6779 931 1501
assert_eq "an explicit fan driver narrows the search" \
    "$(lib "$r" FAN_HWMON=amdgpu -- _find_fan_source)" "1200|amdgpu/fan1"

# ---- --status and --detect read the config file -----------------------------

r="$(new_root)"
add_temp "$r" 0 k10temp Tctl=63500 Tdie=36500
add_temp "$r" 1 k10temp Tctl=65600 Tdie=38600
add_fan  "$r" 2 nct6779 931 1501

cfg="$TMP/custom.env"
printf '%s\n' 'HOG_PCT=70' 'HOG_STRIKES=7' 'THERM_C=65' 'THERM_STRIKES=3' \
    'FAN_RPM=1800' 'FAN_STRIKES=9' > "$cfg"

out="$(watch "$r" "$cfg" --status)"
assert_contains "--status shows the configured thermal threshold" \
    "$out" "thermal     : 65C x 3 samples"
assert_contains "--status shows the configured fan threshold" \
    "$out" "fan         : 1800 RPM x 9 samples"
assert_contains "--status shows the configured hog threshold" \
    "$out" "hog thresh  : 70% of one core x 7 samples"
assert_contains "--status reads the hottest die" "$out" "cpu temp now: 38C"

# Control: with no config file the same command must show the defaults,
# or the three assertions above would pass on any output at all.
out="$(watch "$r" "$TMP/absent.env" --status)"
assert_contains "--status falls back to defaults without a config file" \
    "$out" "thermal     : 92C x 5 samples"

override="$TMP/override.env"
printf '%s\n' 'THERM_HWMON=k10temp' 'THERM_LABEL=Tctl' > "$override"
out="$(watch "$r" "$override" --detect)"
assert_contains "--detect honours a sensor override from the config file" \
    "$out" "using   : k10temp / Tctl"
assert_contains "--detect reads the hottest device for that override" \
    "$out" "reads   : 65 C"

out="$(watch "$r" "$TMP/absent.env" --detect)"
assert_contains "--detect auto-selects Tdie without a config file" \
    "$out" "using   : k10temp / Tdie"
assert_contains "--detect says when several devices share the driver" \
    "$out" "devices : 2, the hottest is read"

r1="$(new_root)"
add_temp "$r1" 0 k10temp Tctl=68000 Tdie=41000
out="$(watch "$r1" "$TMP/absent.env" --detect)"
assert_lacks "--detect stays quiet about device count when there is one" \
    "$out" "devices :"

# ---- the sampling run still honours the config file -------------------------

hot="$TMP/hot.env"
printf '%s\n' 'THERM_C=30' 'THERM_STRIKES=1' > "$hot"
out="$(watch "$r" "$hot" --dry-run)"
assert_contains "a sampling run alerts at a configured threshold" \
    "$out" "would alert thermal temp=38"

cool="$TMP/cool.env"
printf '%s\n' 'THERM_C=65' 'THERM_STRIKES=1' > "$cool"
rm -f "$TMP/run/cpu-hog-watch/state"
out="$(watch "$r" "$cool" --dry-run)"
assert_lacks "a sampling run stays quiet below the configured threshold" \
    "$out" "would alert thermal"

# -----------------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
