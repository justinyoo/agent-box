#!/usr/bin/env bash

write_hook_message() {
    local message=$1 color=''
    if [[ -t 1 && -z "${NO_COLOR:-}" && -z "${CI:-}" && "${TERM:-}" != dumb ]]; then
        case "$message" in
            '[PASS]'*) color=32 ;;
            '[FAIL]'*) color=31 ;;
            '[WARN]'*) color=33 ;;
            '[MANUAL]'*) color=36 ;;
            '[INFO]'*) color=34 ;;
        esac
    fi
    if [[ -n "$color" ]]; then
        printf '\033[%sm%s\033[0m\n' "$color" "$message"
    else
        printf '%s\n' "$message"
    fi
}
