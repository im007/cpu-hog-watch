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

# add_pwm ROOT INDEX DRIVER DUTY:ENABLE:RPM...
# One fan header per triple. An empty ENABLE leaves pwmN_enable out,
# which is how amdgpu looks when it does not expose the control mode.
add_pwm() {
    local root="$1" idx="$2" drv="$3" d n=0 triple duty en rpm
    shift 3
    d="$root/hwmon$idx"
    mkdir -p "$d"
    printf '%s\n' "$drv" > "$d/name"
    for triple in "$@"; do
        n=$(( n + 1 ))
        duty="${triple%%:*}"; rpm="${triple##*:}"
        en="${triple#*:}"; en="${en%:*}"
        printf '%s\n' "$duty" > "$d/pwm$n"
        [ -n "$en" ] && printf '%s\n' "$en" > "$d/pwm${n}_enable"
        printf '1\n' > "$d/pwm${n}_mode"
        printf '%s\n' "$rpm" > "$d/fan${n}_input"
    done
}

# A notify-send that records its arguments and answers nothing. The
# sampling run refuses to start without the real one, so this keeps the
# suite independent of the host, guarantees no test raises a real
# notification, and - because it never prints "kill" - guarantees no
# test can reach the code that signals a process.
stub_notify() {
    mkdir -p "$TMP/bin"
    [ -x "$TMP/bin/notify-send" ] && return 0
    printf '#!/bin/sh\nprintf "%%s\\n" "$@" >> "%s"\nexit 0\n' \
        "$TMP/notify.log" > "$TMP/bin/notify-send"
    chmod +x "$TMP/bin/notify-send"
}

# Run the watcher against a fake root with its own state directory.
# watch ROOT ENV_FILE [ARGS...]
watch() {
    local root="$1" envf="$2"; shift 2
    mkdir -p "$TMP/run"
    stub_notify
    PATH="$TMP/bin:$PATH" XDG_RUNTIME_DIR="$TMP/run" \
        CPU_HOG_HWMON_ROOT="$root" CPU_HOG_ENV_FILE="$envf" \
        "$WATCH" "$@" 2>&1
}

# Run the notifier and print what it would have shown.
# popup ROOT ENV_FILE ARGS...
popup() {
    local root="$1" envf="$2"; shift 2
    stub_notify
    : > "$TMP/notify.log"
    PATH="$TMP/bin:$PATH" CPU_HOG_HWMON_ROOT="$root" \
        CPU_HOG_ENV_FILE="$envf" "$REPO/cpu-hog-notify" "$@" >/dev/null 2>&1
    cat "$TMP/notify.log"
}

# One sampling run from a clean state, so strikes never carry over.
# sample ROOT ENV_FILE
sample() {
    rm -f "$TMP/run/cpu-hog-watch/state"
    watch "$1" "$2" --dry-run
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
    "$out" "fan         : 1800 RPM or 95% duty x 9 samples"
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

# ---- a stopped fan is still a fan -------------------------------------------

# A GPU idling in zero-RPM mode. Reporting it as "no fan controller"
# called a working sensor a missing one.
r="$(new_root)"
add_fan "$r" 0 amdgpu 0
assert_eq "a stopped fan is found" \
    "$(lib "$r" -- _find_fan_source)" "0|amdgpu/fan1"
assert_eq "a stopped fan reads as 0 RPM" "$(lib "$r" -- _max_fan_rpm)" "0"

r="$(new_root)"
add_temp "$r" 0 k10temp Tdie=40000
if lib "$r" -- _find_fan_source >/dev/null 2>&1; then
    fail "no fan controller reports failure" "found a fan where there is none"
else
    ok "no fan controller reports failure"
fi

# ---- fan duty: which fan counts ---------------------------------------------

# The X399M Taichi this was measured on: five headers under Smart Fan
# IV (enable=5), one of them with nothing plugged in.
r="$(new_root)"
add_pwm "$r" 0 nct6779 165:5:928 184:5:1059 165:5:1503 165:5:0 165:5:974
assert_eq "the hardest-driven automatic fan is reported" \
    "$(lib "$r" -- _find_fan_duty)" "72|nct6779/fan2|1059"

r="$(new_root)"
add_pwm "$r" 0 nct6779 255:1:2000 120:5:900
assert_eq "a fan set by hand is left out" \
    "$(lib "$r" -- _find_fan_duty)" "47|nct6779/fan2|900"

r="$(new_root)"
add_pwm "$r" 0 nct6779 255:0:2000 120:2:900
assert_eq "a fan fixed at full speed is left out" \
    "$(lib "$r" -- _find_fan_duty)" "47|nct6779/fan2|900"

r="$(new_root)"
add_pwm "$r" 0 nct6779 255:5:0 150:5:1000
assert_eq "a header with nothing spinning is left out" \
    "$(lib "$r" -- _find_fan_duty)" "58|nct6779/fan2|1000"

r="$(new_root)"
add_pwm "$r" 0 amdgpu 200::1400
if lib "$r" -- _find_fan_duty >/dev/null 2>&1; then
    fail "a fan with no control mode reports no duty" "duty was reported"
else
    ok "a fan with no control mode reports no duty"
fi

r="$(new_root)"
add_pwm "$r" 0 amdgpu 230:2:2100
add_pwm "$r" 1 nct6779 120:5:900
assert_eq "an explicit fan driver narrows the duty search" \
    "$(lib "$r" FAN_HWMON=nct6779 -- _find_fan_duty)" "47|nct6779/fan1|900"

# ---- fan backstop: speed or duty --------------------------------------------

one="$TMP/one-strike.env"
printf '%s\n' 'FAN_STRIKES=1' 'THERM_C=200' > "$one"

# Flat out, yet nowhere near the laptop-sized 4500 RPM default.
r="$(new_root)"
add_temp "$r" 0 k10temp Tdie=40000
add_pwm  "$r" 1 nct6779 250:5:1900 120:5:900
out="$(sample "$r" "$one")"
assert_contains "a fan at full duty trips the backstop below FAN_RPM" \
    "$out" "would alert thermal fan=1900"

r="$(new_root)"
add_temp "$r" 0 k10temp Tdie=40000
add_pwm  "$r" 1 nct6779 184:5:1059 165:5:1503
out="$(sample "$r" "$one")"
assert_lacks "a fan at ordinary duty stays quiet" "$out" "would alert thermal"

# The pinned fan is the slow one; the fast one is idling.
r="$(new_root)"
add_temp "$r" 0 k10temp Tdie=40000
add_pwm  "$r" 1 nct6779 255:5:800 100:5:1500
out="$(sample "$r" "$one")"
assert_contains "a duty trip quotes the pinned fan, not the fastest" \
    "$out" "would alert thermal fan=800"

off="$TMP/duty-off.env"
printf '%s\n' 'FAN_STRIKES=1' 'THERM_C=200' 'FAN_DUTY_PCT=101' > "$off"
r="$(new_root)"
add_temp "$r" 0 k10temp Tdie=40000
add_pwm  "$r" 1 nct6779 255:5:1900
out="$(sample "$r" "$off")"
assert_lacks "FAN_DUTY_PCT above 100 turns the duty check off" \
    "$out" "would alert thermal"

rpm_only="$TMP/rpm.env"
printf '%s\n' 'FAN_STRIKES=1' 'THERM_C=200' 'FAN_RPM=1000' > "$rpm_only"
r="$(new_root)"
add_temp "$r" 0 k10temp Tdie=40000
add_fan  "$r" 1 dell_smm 1500
out="$(sample "$r" "$rpm_only")"
assert_contains "FAN_RPM still trips where no duty is reported" \
    "$out" "would alert thermal fan=1500"

# ---- duty in --status and --detect ------------------------------------------

r="$(new_root)"
add_temp "$r" 0 k10temp Tdie=40000
add_pwm  "$r" 1 nct6779 165:5:928 184:5:1059
out="$(watch "$r" "$TMP/absent.env" --status)"
assert_contains "--status shows the live duty" "$out" "duty now    : 72%"
out="$(watch "$r" "$TMP/absent.env" --detect)"
assert_contains "--detect names the fan the duty check reads" \
    "$out" "using   : nct6779/fan2 (72% duty, 1059 RPM)"

r="$(new_root)"
add_temp "$r" 0 k10temp Tdie=40000
add_fan  "$r" 1 dell_smm 1500
out="$(watch "$r" "$TMP/absent.env" --status)"
assert_contains "--status says so when no duty is reported" \
    "$out" "duty now    : not reported"
out="$(watch "$r" "$TMP/absent.env" --detect)"
assert_contains "--detect says only FAN_RPM can trip without a duty" \
    "$out" "only FAN_RPM can"

# ---- the popup reads the same config as the watcher -------------------------

r="$(new_root)"
add_temp "$r" 0 k10temp Tctl=63500 Tdie=36500
add_temp "$r" 1 k10temp Tctl=65600 Tdie=38600
add_fan  "$r" 2 amdgpu 1200
add_fan  "$r" 3 nct6779 931 1501

out="$(popup "$r" "$TMP/absent.env" thermal fan 1501 5)"
assert_contains "the popup shows the auto-selected temperature" \
    "$out" "CPU 38 °C"

out="$(popup "$r" "$override" thermal fan 1501 5)"
assert_contains "the popup honours a temperature override" \
    "$out" "CPU 65 °C"

fan_override="$TMP/fan-override.env"
printf '%s\n' 'FAN_HWMON=amdgpu' > "$fan_override"
out="$(popup "$r" "$fan_override" hog "$$" 0 testproc 99 12 40 false)"
assert_contains "the popup honours a fan override" "$out" "fan 1200 RPM"

out="$(popup "$r" "$TMP/absent.env" hog "$$" 0 testproc 99 12 40 false)"
assert_contains "the popup shows the fastest fan without an override" \
    "$out" "fan 1501 RPM"

# -----------------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
