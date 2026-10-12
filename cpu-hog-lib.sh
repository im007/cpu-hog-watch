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
# Library: cpu-hog-lib.sh
# Purpose: Sensor discovery shared by cpu-hog-watch and cpu-hog-notify,
#          so the two can never drift apart on how heat is measured.
# Usage:   sourced, not executed.
#

# Where the kernel exposes hardware monitors. Overridable so the tests
# can point discovery at a fake tree; nothing else should set it.
CPU_HOG_HWMON_ROOT="${CPU_HOG_HWMON_ROOT:-/sys/class/hwmon}"

# Ordered probe list for CPU package temperature: "driver|label".
# An empty label means "this driver exposes one temperature, take it".
#
# Tdie precedes Tctl deliberately. Per the kernel's k10temp
# documentation Tdie is the real measured die temperature, while Tctl
# is a control value on an arbitrary scale that does NOT represent a
# physical temperature - it only drives fan curves. Tctl is always
# present; Tdie only on CPUs that report it.
#
# Order matters: the first probe that resolves wins.
CPU_HOG_THERM_PROBES=(
    "k10temp|Tdie"           # AMD, real die temperature
    "k10temp|Tctl"           # AMD, control value (always available)
    "zenpower|Tdie"          # AMD, out-of-tree driver
    "coretemp|Package id 0"  # Intel, Sandy Bridge and newer
    "coretemp|Physical id 0" # Intel, label varies on some systems
    "cpu_thermal|"           # ARM SoCs
    "acpitz*|"               # generic ACPI zone, last resort
)

# Drivers whose reading is NOT guaranteed to be the CPU. An ACPI
# thermal zone may report skin, battery or chassis temperature, and a
# machine often exposes several that disagree. Auto-selection still
# uses one rather than leaving no backstop at all, but every readout
# path labels it so nobody mistakes a guess for a measurement.
CPU_HOG_GENERIC_THERM="acpitz"

# True if $1 names a source that may not be the CPU.
_therm_is_generic() {
    case "$1" in "$CPU_HOG_GENERIC_THERM"*) return 0 ;; esac
    return 1
}

# Print every hwmon directory whose name file matches $1, one per line.
# hwmon NUMBERING IS NOT STABLE ACROSS BOOTS, so never address these
# by number - k10temp can be hwmon12 on one boot and hwmon9 on the
# next.
#
# A driver can appear MORE THAN ONCE. A Threadripper exposes one
# k10temp per die and a dual-socket board one coretemp per package, so
# "the k10temp device" is not a thing that can be assumed to exist.
_hwmon_all_by_name() {
    local want="$1" h n pre rc=1
    for h in "$CPU_HOG_HWMON_ROOT"/hwmon*; do
        [ -r "$h/name" ] || continue
        n="$(cat "$h/name" 2>/dev/null)"
        case "$want" in
            *\*)
                # Prefix probe. Machines expose acpitz_0, acpitz_1 and
                # so on rather than a bare "acpitz".
                pre="${want%\*}"
                [ "${n#"$pre"}" != "$n" ] || continue
                ;;
            *)
                [ "$n" = "$want" ] || continue
                ;;
        esac
        printf '%s\n' "$h"; rc=0
    done
    return "$rc"
}

# Print the first hwmon directory whose name file matches $1. Enough
# for asking whether a driver is present or what it is really called;
# never use it to pick a temperature - see _temp_input_for.
_hwmon_by_name() {
    local all
    all="$(_hwmon_all_by_name "$1")" || return 1
    printf '%s\n' "${all%%$'\n'*}"
}

# Print the real hwmon name behind a probe pattern (acpitz* -> acpitz_0).
_hwmon_real_name() {
    local h; h="$(_hwmon_by_name "$1")" || return 1
    cat "$h/name" 2>/dev/null
}

# Print the temp*_input path for driver $1 and label $2, if present.
# An empty $2 matches a driver exposing exactly one temperature.
#
# When several devices carry the driver, the HOTTEST one wins. The
# backstop exists to catch heat, and the first device enumerated is not
# reliably the warmest: reading only it left one Threadripper die
# unwatched. The answer can therefore differ from one call to the next.
_temp_input_for() {
    local drv="$1" want="$2" h lbl inp cand v
    local best="" best_v="" first=""
    while IFS= read -r h; do
        inp=""
        if [ -z "$want" ]; then
            for cand in "$h"/temp*_input; do
                [ -r "$cand" ] && { inp="$cand"; break; }
            done
        else
            for lbl in "$h"/temp*_label; do
                [ -r "$lbl" ] || continue
                [ "$(cat "$lbl" 2>/dev/null)" = "$want" ] || continue
                cand="${lbl%_label}_input"
                [ -r "$cand" ] && { inp="$cand"; break; }
            done
        fi
        [ -n "$inp" ] || continue
        [ -n "$first" ] || first="$inp"
        v="$(cat "$inp" 2>/dev/null)"
        # Millidegrees, possibly negative. Anything else is a sensor
        # that did not answer, and must not win the comparison.
        case "${v#-}" in ''|*[!0-9]*) continue ;; esac
        if [ -z "$best" ] || [ "$v" -gt "$best_v" ]; then
            best="$inp"; best_v="$v"
        fi
    done < <(_hwmon_all_by_name "$drv")
    # No device answered with a number: still name the first match, so
    # one failed read does not make the driver look absent.
    [ -n "$best" ] || best="$first"
    [ -n "$best" ] || return 1
    printf '%s\n' "$best"
}

# Print "<path>|<driver>|<label>" for the CPU temperature source.
# Honours an explicit THERM_HWMON; otherwise walks the probe list.
_find_temp_source() {
    local entry drv lbl path
    if [ -n "${THERM_HWMON:-}" ] && [ "${THERM_HWMON}" != "auto" ]; then
        path="$(_temp_input_for "$THERM_HWMON" "${THERM_LABEL:-}")" \
            || return 1
        printf '%s|%s|%s\n' "$path" "$THERM_HWMON" "${THERM_LABEL:-}"
        return 0
    fi
    for entry in "${CPU_HOG_THERM_PROBES[@]}"; do
        drv="${entry%%|*}"; lbl="${entry#*|}"
        path="$(_temp_input_for "$drv" "$lbl")" || continue
        printf '%s|%s|%s\n' "$path" "$drv" "$lbl"
        return 0
    done
    return 1
}

# CPU package temperature in whole degrees C.
_cpu_temp_c() {
    local src path v
    src="$(_find_temp_source)" || return 1
    path="${src%%|*}"
    [ -r "$path" ] || return 1
    v="$(cat "$path" 2>/dev/null)"
    case "${v#-}" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$(( v / 1000 ))"
}

# Print "<rpm>|<driver>" for the fastest fan on the machine.
# Fans need no driver list: any hwmon exposing fan*_input is a fan
# controller, whoever made it. Explicit FAN_HWMON narrows it.
_find_fan_source() {
    # max starts below zero so a STOPPED fan still counts as a fan. A
    # GPU idling in zero-RPM mode used to read as "no fan controller",
    # which reported a working sensor as a missing one.
    local h n f v max=-1 who=""
    for h in "$CPU_HOG_HWMON_ROOT"/hwmon*; do
        n="$(cat "$h/name" 2>/dev/null)" || continue
        if [ -n "${FAN_HWMON:-}" ] && [ "${FAN_HWMON}" != "auto" ]; then
            [ "$n" = "$FAN_HWMON" ] || continue
        fi
        for f in "$h"/fan*_input; do
            [ -r "$f" ] || continue
            v="$(cat "$f" 2>/dev/null)" || continue
            case "$v" in ''|*[!0-9]*) continue ;; esac
            if [ "$v" -gt "$max" ]; then
                max="$v"; who="$n/$(basename "$f" _input)"
            fi
        done
    done
    [ -n "$who" ] || return 1
    printf '%s|%s\n' "$max" "$who"
}

# Print "<percent>|<driver>/<fan>|<rpm>" for the hardest-driven fan.
#
# Duty is how hard the controller is pushing a fan: pwmN, 0-255. Unlike
# RPM it means the same thing on every machine. 4500 RPM is flat out
# for a laptop blower and unreachable for a 140 mm case fan, so an RPM
# threshold tuned on one can never fire on the other.
#
# Two kinds of fan are left out, because neither says anything about
# heat and either would otherwise read as permanently pinned:
#   - one not under AUTOMATIC control. pwmN_enable is 0 for "no
#     control, full speed", 1 for "set by hand", and 2 or more for
#     automatic, per the kernel's hwmon sysfs interface;
#   - a header with nothing spinning on it, which still carries a duty.
_find_fan_duty() {
    local h n p i en v rpm pct max=-1 who="" at=""
    for h in "$CPU_HOG_HWMON_ROOT"/hwmon*; do
        n="$(cat "$h/name" 2>/dev/null)" || continue
        if [ -n "${FAN_HWMON:-}" ] && [ "${FAN_HWMON}" != "auto" ]; then
            [ "$n" = "$FAN_HWMON" ] || continue
        fi
        for p in "$h"/pwm[0-9]*; do
            i="${p##*/pwm}"
            # The glob also matches pwm1_enable, pwm1_mode and friends.
            case "$i" in ''|*[!0-9]*) continue ;; esac
            [ -r "$p" ] || continue
            en="$(cat "${p}_enable" 2>/dev/null)"
            case "$en" in ''|*[!0-9]*) continue ;; esac
            [ "$en" -ge 2 ] || continue
            rpm="$(cat "$h/fan${i}_input" 2>/dev/null)"
            case "$rpm" in ''|*[!0-9]*) continue ;; esac
            [ "$rpm" -gt 0 ] || continue
            v="$(cat "$p" 2>/dev/null)"
            case "$v" in ''|*[!0-9]*) continue ;; esac
            pct=$(( v * 100 / 255 ))
            if [ "$pct" -gt "$max" ]; then
                max="$pct"; who="$n/fan$i"; at="$rpm"
            fi
        done
    done
    [ -n "$who" ] || return 1
    printf '%s|%s|%s\n' "$max" "$who" "$at"
}

# Source the env file $1, exporting what it sets. Shared so the watcher
# and the notifier read the same file the same way: a sensor override
# that reached only one of them would have the popup quote a different
# temperature from the one that raised it.
_load_env_file() {
    [ -r "$1" ] || return 1
    set -a
    # shellcheck disable=SC1090  # resolved at runtime by design
    . "$1"
    set +a
}

# Highest fan RPM reported by any fan controller.
_max_fan_rpm() {
    local src
    src="$(_find_fan_source)" || return 1
    printf '%s\n' "${src%%|*}"
}

# Print "<largest max>|<fans with a max>|<fans without>" over every fan
# that answers. fanN_max is the fastest a fan says it can turn; few
# drivers expose it, so the two counts matter as much as the number.
_fan_max_summary() {
    local h n f v m largest=0 known=0 unknown=0
    for h in "$CPU_HOG_HWMON_ROOT"/hwmon*; do
        n="$(cat "$h/name" 2>/dev/null)" || continue
        if [ -n "${FAN_HWMON:-}" ] && [ "${FAN_HWMON}" != "auto" ]; then
            [ "$n" = "$FAN_HWMON" ] || continue
        fi
        for f in "$h"/fan*_input; do
            [ -r "$f" ] || continue
            v="$(cat "$f" 2>/dev/null)"
            case "$v" in ''|*[!0-9]*) continue ;; esac
            m="$(cat "${f%_input}_max" 2>/dev/null)"
            case "$m" in ''|*[!0-9]*) m=0 ;; esac
            if [ "$m" -gt 0 ]; then
                known=$(( known + 1 ))
                [ "$m" -gt "$largest" ] && largest="$m"
            else
                unknown=$(( unknown + 1 ))
            fi
        done
    done
    printf '%s|%s|%s\n' "$largest" "$known" "$unknown"
}

# Can each backstop actually fire on this machine?
# _backstop_verdicts THERM_C FAN_RPM FAN_DUTY_PCT
#
# Prints one line per backstop, "<kind>|<state>|<why>", kind being temp
# or fan. A threshold the hardware can never reach is a safety net that
# exists on paper only: a 92 C limit on a CPU rated for 68, or a 4500
# RPM limit on fans that top out at 1500, alerts on nothing and says
# nothing about it.
#
# There are THREE states, and the third must never be reported as the
# first:
#   ok        - checked against something the hardware reports, and
#               reachable;
#   dead      - checked, and unreachable;
#   unchecked - the hardware reports nothing to check against. That is
#               not "fine". k10temp on a Threadripper exposes no limit
#               at all, so its threshold can only be checked by a
#               person against the CPU's rated maximum.
#
# Only temp*_crit proves a temperature threshold dead. temp*_max is a
# warning mark the CPU may run above, so passing it proves nothing.
_backstop_verdicts() {
    local therm_c="$1" fan_rpm="$2" duty_pct="$3"
    local src path drv crit sum largest known unknown

    if src="$(_find_temp_source)"; then
        path="${src%%|*}"
        drv="$(_hwmon_real_name "$(printf '%s' "$src" | cut -d'|' -f2)")"
        crit="$(cat "${path%_input}_crit" 2>/dev/null)"
        case "$crit" in ''|*[!0-9]*) crit=0 ;; esac
        if [ "$crit" -le 0 ]; then
            printf 'temp|unchecked|%s reports no critical limit; compare THERM_C=%s with the rated maximum of this CPU\n' \
                "$drv" "$therm_c"
        elif [ "$(( therm_c * 1000 ))" -ge "$crit" ]; then
            printf 'temp|dead|THERM_C=%s is at or above the %s C critical limit %s reports\n' \
                "$therm_c" "$(( crit / 1000 ))" "$drv"
        else
            printf 'temp|ok|THERM_C=%s is below the %s C critical limit %s reports\n' \
                "$therm_c" "$(( crit / 1000 ))" "$drv"
        fi
    else
        printf 'temp|dead|no CPU temperature sensor was found\n'
    fi

    if ! _find_fan_source >/dev/null; then
        printf 'fan|dead|no fan controller was found\n'
        return 0
    fi
    if [ "$duty_pct" -le 100 ] && src="$(_find_fan_duty)"; then
        printf 'fan|ok|%s reports its duty, so FAN_DUTY_PCT=%s can be reached\n' \
            "$(printf '%s' "$src" | cut -d'|' -f2)" "$duty_pct"
        return 0
    fi
    # Speed is the only way left to trip it.
    sum="$(_fan_max_summary)"
    largest="${sum%%|*}"; unknown="${sum##*|}"
    known="${sum#*|}"; known="${known%|*}"
    if [ "$unknown" -gt 0 ] || [ "$known" -eq 0 ]; then
        printf 'fan|unchecked|no usable duty, and not every fan states a maximum, so FAN_RPM=%s cannot be checked\n' \
            "$fan_rpm"
    elif [ "$fan_rpm" -gt "$largest" ]; then
        printf 'fan|dead|FAN_RPM=%s is above the highest stated fan maximum of %s RPM, with no usable duty\n' \
            "$fan_rpm" "$largest"
    else
        printf 'fan|ok|FAN_RPM=%s is within the highest stated fan maximum of %s RPM\n' \
            "$fan_rpm" "$largest"
    fi
}
