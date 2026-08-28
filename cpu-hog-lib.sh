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

# Print the hwmon directory whose name file matches $1.
# hwmon NUMBERING IS NOT STABLE ACROSS BOOTS, so never address these
# by number - k10temp can be hwmon12 on one boot and hwmon9 on the
# next.
_hwmon_by_name() {
    local want="$1" h n pre
    for h in /sys/class/hwmon/hwmon*; do
        [ -r "$h/name" ] || continue
        n="$(cat "$h/name" 2>/dev/null)"
        case "$want" in
            *\*)
                # Prefix probe. Machines expose acpitz_0, acpitz_1 and
                # so on rather than a bare "acpitz".
                pre="${want%\*}"
                if [ "${n#"$pre"}" != "$n" ]; then
                    printf '%s\n' "$h"; return 0
                fi
                ;;
            *)
                if [ "$n" = "$want" ]; then printf '%s\n' "$h"; return 0; fi
                ;;
        esac
    done
    return 1
}

# Print the real hwmon name behind a probe pattern (acpitz* -> acpitz_0).
_hwmon_real_name() {
    local h; h="$(_hwmon_by_name "$1")" || return 1
    cat "$h/name" 2>/dev/null
}

# Print the temp*_input path for driver $1 and label $2, if present.
# An empty $2 matches a driver exposing exactly one temperature.
_temp_input_for() {
    local drv="$1" want="$2" h lbl inp
    h="$(_hwmon_by_name "$drv")" || return 1

    if [ -z "$want" ]; then
        for inp in "$h"/temp*_input; do
            [ -r "$inp" ] && { printf '%s\n' "$inp"; return 0; }
        done
        return 1
    fi

    for lbl in "$h"/temp*_label; do
        [ -r "$lbl" ] || continue
        [ "$(cat "$lbl" 2>/dev/null)" = "$want" ] || continue
        inp="${lbl%_label}_input"
        [ -r "$inp" ] && { printf '%s\n' "$inp"; return 0; }
    done
    return 1
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
    local src path
    src="$(_find_temp_source)" || return 1
    path="${src%%|*}"
    [ -r "$path" ] || return 1
    printf '%s\n' "$(( $(cat "$path") / 1000 ))"
}

# Print "<rpm>|<driver>" for the fastest fan on the machine.
# Fans need no driver list: any hwmon exposing fan*_input is a fan
# controller, whoever made it. Explicit FAN_HWMON narrows it.
_find_fan_source() {
    local h n f v max=0 who=""
    for h in /sys/class/hwmon/hwmon*; do
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

# Highest fan RPM reported by any fan controller.
_max_fan_rpm() {
    local src
    src="$(_find_fan_source)" || return 1
    printf '%s\n' "${src%%|*}"
}
