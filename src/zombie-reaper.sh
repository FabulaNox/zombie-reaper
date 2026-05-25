#!/usr/bin/env bash
# zombie-reaper.sh - track and safely reap zombie processes
# Usage: zombie-reaper.sh [--list|--nudge|--dry-run]
#
#   --list      (default) report zombies and recommended action
#   --nudge     send SIGCHLD to each zombie's parent to trigger reaping
#   --dry-run   show what --nudge would do, without doing it
#
# Environment:
#   ZOMBIE_REAPER_PROTECTED   Extended-regex of parent process names that should
#                             only ever receive SIGCHLD (never escalated). Anchored
#                             with ^...$ so write alternation as foo|bar|baz.
#   ZOMBIE_REAPER_STALE_SECS  Threshold in seconds above which a zombie is "stale"
#                             and produces a warn-level log. Default 302400 (3.5d).
#   ZOMBIE_REAPER_LOG         Path to the append-only JSONL run log. Default by
#                             privilege (/var/log/... as root, $XDG_STATE_HOME/...
#                             otherwise). Set to "" to disable file logging.
#   ZOMBIE_REAPER_LOG_MAX_BYTES  Rotate the log when it reaches this size. Default
#                             1048576 (1 MiB). Footprint normally bounded to 2x
#                             (file + one rotated .1). Non-numeric => default.

: "${ZOMBIE_REAPER_PROTECTED:=systemd|init|wazuh|ossec|dockerd|containerd|sshd}"
: "${ZOMBIE_REAPER_STALE_SECS:=302400}"

PROTECTED_PARENTS="^(${ZOMBIE_REAPER_PROTECTED})$"
STALE_SECS="${ZOMBIE_REAPER_STALE_SECS}"

# ZOMBIE_REAPER_LOG: append-only JSONL record path. Default chosen by privilege.
# An explicitly empty value disables file logging (journal only) - so test for
# "set" rather than using := which would overwrite an intentional empty string.
if [[ -z "${ZOMBIE_REAPER_LOG+set}" ]]; then
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        ZOMBIE_REAPER_LOG="/var/log/zombie-reaper/reaper.jsonl"
    else
        ZOMBIE_REAPER_LOG="${XDG_STATE_HOME:-$HOME/.local/state}/zombie-reaper/reaper.jsonl"
    fi
fi

# Rotation threshold in bytes; on success the on-disk footprint is bounded to 2x
# this (current file + one rotated .1). A rotation failure bypasses the cap.
: "${ZOMBIE_REAPER_LOG_MAX_BYTES:=1048576}"
# A non-numeric value would crash the later (( ... )) under set -u; fall back.
[[ "$ZOMBIE_REAPER_LOG_MAX_BYTES" =~ ^[0-9]+$ ]] || ZOMBIE_REAPER_LOG_MAX_BYTES=1048576

log() { echo "[$(date '+%Y-%m-%d %T')] $*"; }

# Escape a string for safe inclusion inside a JSON double-quoted value.
# Backslash MUST be escaped first, or later escapes would be double-escaped.
json_escape() {
    local s=${1:-}   # ${1:-} not $1: stay safe under set -u if called bare
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\t'/\\t}
    s=${s//$'\r'/\\r}
    s=${s//$'\n'/\\n}
    printf '%s' "$s"
}

# True when a ps STAT field denotes a zombie (leading char 'Z').
stat_is_zombie() {
    local stat=${1:-}   # ${1:-} not $1: safe under set -u if called bare
    [[ ${stat:0:1} == "Z" ]]
}

# True when pid is a kernel thread: /proc/<pid>/cmdline exists but is empty.
# NOTE: a zombie also has an empty cmdline, so callers MUST test stat_is_zombie
# first - see main()'s classification order.
# NOTE: /proc files report stat()-size 0 even when non-empty (kernel generates
# content on read), and cmdline uses NUL separators (read -r fails on NUL).
# Use wc -c which actually reads bytes from the file descriptor.
is_kernel_thread() {
    local pid=${1:-}   # ${1:-} not $1: safe under set -u if called bare
    local bytes
    [[ -n "$pid" && -e "/proc/$pid/cmdline" ]] || return 1
    bytes=$(wc -c < "/proc/$pid/cmdline" 2>/dev/null) || return 1
    [[ "$bytes" -eq 0 ]]
}

# Append one JSON line to ZOMBIE_REAPER_LOG, rotating first if at/over the size
# cap. Best-effort: any failure logs a warning to the journal and returns 0 so a
# logging problem never aborts the reap (important under set -euo pipefail).
write_log_record() {
    local line=${1:-}
    [[ -z "$ZOMBIE_REAPER_LOG" ]] && return 0

    local dir
    dir=$(dirname -- "$ZOMBIE_REAPER_LOG")
    if ! mkdir -p -- "$dir" 2>/dev/null; then
        log "  ⚠ log: cannot create $dir; skipping file log"
        return 0
    fi

    if [[ -f "$ZOMBIE_REAPER_LOG" ]]; then
        local size
        size=$(stat -c %s -- "$ZOMBIE_REAPER_LOG" 2>/dev/null || echo 0)
        if (( size >= ZOMBIE_REAPER_LOG_MAX_BYTES )); then
            mv -f -- "$ZOMBIE_REAPER_LOG" "${ZOMBIE_REAPER_LOG}.1" 2>/dev/null \
                || log "  ⚠ log: rotation failed; continuing"
        fi
    fi

    printf '%s\n' "$line" >> "$ZOMBIE_REAPER_LOG" 2>/dev/null \
        || log "  ⚠ log: append to $ZOMBIE_REAPER_LOG failed"
    return 0
}

# Given a parent command name and its uptime in seconds, return one of:
#   sigchld  - safe to nudge
#   warn     - nudge, but log a warning (stale)
#   skip     - do nothing (parent already gone or unusable)
escalation_action() {
    local pcmd="$1"
    local page="${2:-0}"

    if [[ -z "$pcmd" || "$pcmd" == "<dead parent>" ]]; then
        echo "skip"
    elif [[ $pcmd =~ $PROTECTED_PARENTS && $page -gt $STALE_SECS ]]; then
        echo "warn"
    elif [[ $pcmd =~ $PROTECTED_PARENTS ]]; then
        echo "sigchld"
    elif [[ $page -gt $STALE_SECS ]]; then
        echo "warn"
    else
        echo "sigchld"
    fi
}

main() {
    local mode="${1:---list}"
    local mode_label="${mode#--}"   # list | nudge | dry-run

    local host ts
    host=$(hostname 2>/dev/null || echo "")
    ts=$(date '+%Y-%m-%dT%T%:z')   # %:z -> RFC-3339 offset (+03:00), matches docs

    mapfile -t ZOMBIES < <(ps -eo pid=,ppid=,comm=,stat= | awk '$4=="Z" {print $1, $2, $3}')

    if [[ ${#ZOMBIES[@]} -eq 0 ]]; then
        log "No zombie processes found."
        write_log_record "$(printf \
            '{"ts":"%s","host":"%s","mode":"%s","zombies_found":0,"parents_nudged":0,"reaped":0,"remaining":0,"warnings":0,"parents":[]}' \
            "$ts" "$(json_escape "$host")" "$mode_label")"
        return 0
    fi

    log "Found ${#ZOMBIES[@]} zombie(s)."
    printf "\n%-8s %-8s %-25s %s\n" "ZOM-PID" "PAR-PID" "ZOMBIE-CMD" "PARENT-CMD"
    printf "%-8s %-8s %-25s %s\n"   "-------" "-------" "---------" "----------"

    # Per-parent (keyed by parent pid) accumulators.
    local -A p_cmd p_found p_action p_skip p_reaped
    local parents_order=()
    local nudge_pids=()
    local zpid ppid zcmd parent_cmd parent_age parent_stat action skip_reason

    for entry in "${ZOMBIES[@]}"; do
        read -r zpid ppid zcmd <<< "$entry"

        parent_cmd=$(ps -o comm= -p "$ppid" 2>/dev/null || true)
        parent_age=$(ps -o etimes= -p "$ppid" 2>/dev/null | tr -d ' ' || true)
        parent_stat=$(ps -o stat= -p "$ppid" 2>/dev/null || true)

        action=""
        skip_reason="null"

        # Classification order matters: gone -> defunct(Z) -> kernel-thread -> escalate.
        # A zombie's cmdline is also empty, so the Z test MUST precede is_kernel_thread.
        if [[ -z "$parent_cmd" ]]; then
            parent_cmd="<gone>"
            action="skip"; skip_reason="gone"
            log "  ↳ PID $zpid ($zcmd): skipping - parent $ppid gone; will reparent to init and self-reap"
        elif stat_is_zombie "$parent_stat"; then
            action="skip"; skip_reason="defunct"
            log "  ↳ PID $zpid ($zcmd): skipping - parent $parent_cmd ($ppid) is itself defunct; will reparent to init"
        elif is_kernel_thread "$ppid"; then
            action="skip"; skip_reason="kernel-thread"
            log "  ↳ PID $zpid ($zcmd): skipping - parent $parent_cmd ($ppid) is a kernel thread; never signalled"
        else
            action=$(escalation_action "$parent_cmd" "${parent_age:-0}")
            case "$action" in
                sigchld)
                    log "  ↳ PID $zpid ($zcmd): will SIGCHLD parent $parent_cmd (PID $ppid)" ;;
                warn)
                    log "  ⚠ PID $zpid ($zcmd): zombie stale (>${parent_age}s), nudging $parent_cmd - may need manual restart" ;;
            esac
            nudge_pids+=("$ppid")
        fi

        printf "%-8s %-8s %-25s %s %s\n" "$zpid" "$ppid" "$zcmd" "$parent_cmd" \
            "${parent_age:+(${parent_age}s uptime)}"

        # Record this parent once; accumulate its found count.
        if [[ -z "${p_cmd[$ppid]+set}" ]]; then
            parents_order+=("$ppid")
            p_cmd[$ppid]="$parent_cmd"
            p_found[$ppid]=0
            p_action[$ppid]="$action"
            p_skip[$ppid]="$skip_reason"
            p_reaped[$ppid]=0
        fi
        p_found[$ppid]=$(( p_found[$ppid] + 1 ))
    done

    local total_nudged=0 reaped_total=0 remaining=${#ZOMBIES[@]}

    if [[ "$mode" == "--nudge" || "$mode" == "--dry-run" ]]; then
        if [[ ${#nudge_pids[@]} -eq 0 ]]; then
            log "No parents to nudge."
        else
            local unique_pids
            mapfile -t unique_pids < <(printf '%s\n' "${nudge_pids[@]}" | sort -un)

            local up pc
            for up in "${unique_pids[@]}"; do
                [[ -z "$up" ]] && continue
                pc="${p_cmd[$up]:-<gone>}"
                if [[ "$mode" == "--dry-run" ]]; then
                    log "  [dry-run] would send SIGCHLD to $pc (PID $up)"
                else
                    log "  → Sending SIGCHLD to $pc (PID $up)"
                    if kill -CHLD "$up" 2>/dev/null; then
                        log "    ✓ Sent"
                        total_nudged=$(( total_nudged + 1 ))
                    else
                        log "    ✗ Failed (permission denied? install system-scope for full coverage)"
                    fi
                fi
            done
        fi

        if [[ "$mode" == "--nudge" ]]; then
            sleep 2
            # Recount zombie children per parent pid after the settle.
            local -A remaining_by_parent
            local rppid
            while read -r _ rppid; do
                remaining_by_parent[$rppid]=$(( ${remaining_by_parent[$rppid]:-0} + 1 ))
            done < <(ps -eo pid=,ppid=,stat= | awk '$3 ~ /^Z/ {print $1, $2}')

            local rem got
            for ppid in "${parents_order[@]}"; do
                rem=${remaining_by_parent[$ppid]:-0}
                got=$(( ${p_found[$ppid]} - rem ))
                if (( got < 0 )); then got=0; fi
                p_reaped[$ppid]=$got
                reaped_total=$(( reaped_total + got ))
            done

            # awk count (not wc -l) so the value is a clean integer for JSON.
            remaining=$(ps -eo stat= | awk '$1 ~ /^Z/ {c++} END{print c+0}')
            log "Zombies remaining after nudge: $remaining"
            if [[ "$remaining" -gt 0 ]]; then
                # kill -CHLD returns 0 as long as the signal is deliverable; it does
                # NOT guarantee the parent actually called wait(). A parent that
                # ignores SIGCHLD or installs no handler leaves the zombie in place.
                log "  ⚠ Hint: parents accepted SIGCHLD but did not reap. They may not"
                log "    install a SIGCHLD handler (naive parent). Consider restarting"
                log "    the parent process(es) or escalating manually."
            fi
        fi
    elif [[ "$mode" == "--list" ]]; then
        echo
        log "Run with --nudge to send SIGCHLD to parent processes."
    fi

    # Assemble per-parent JSON array and count warnings.
    local parents_json="" first=1 warnings=0 sr_json obj
    for ppid in "${parents_order[@]}"; do
        [[ "${p_action[$ppid]}" == "warn" ]] && warnings=$(( warnings + 1 ))
        if [[ "${p_skip[$ppid]}" == "null" ]]; then
            sr_json="null"
        else
            sr_json="\"$(json_escape "${p_skip[$ppid]}")\""
        fi
        obj=$(printf '{"cmd":"%s","pid":%s,"found":%s,"reaped":%s,"action":"%s","skip_reason":%s}' \
            "$(json_escape "${p_cmd[$ppid]}")" "$ppid" "${p_found[$ppid]}" \
            "${p_reaped[$ppid]}" "${p_action[$ppid]}" "$sr_json")
        if (( first )); then parents_json="$obj"; first=0
        else parents_json="$parents_json,$obj"; fi
    done

    write_log_record "$(printf \
        '{"ts":"%s","host":"%s","mode":"%s","zombies_found":%s,"parents_nudged":%s,"reaped":%s,"remaining":%s,"warnings":%s,"parents":[%s]}' \
        "$ts" "$(json_escape "$host")" "$mode_label" "${#ZOMBIES[@]}" \
        "$total_nudged" "$reaped_total" "$remaining" "$warnings" "$parents_json")"
}

# Only run main when executed directly, so the file can be sourced for testing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
    main "$@"
fi
