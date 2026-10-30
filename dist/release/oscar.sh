#!/usr/bin/env bash
set -Eeuo pipefail

script_path=${BASH_SOURCE[0]}
case $script_path in */*) script_parent=${script_path%/*} ;; *) script_parent=. ;; esac
script_dir=$(CDPATH= cd -- "$script_parent" && pwd)
setup_script="$script_dir/oscar-setup.sh"

open_terminal_menu() {
    case "$(uname -s)" in
        Linux)
            if command -v gnome-terminal >/dev/null 2>&1; then
                gnome-terminal -- bash "$script_dir/oscar.sh" --menu
                return
            fi
            if command -v x-terminal-emulator >/dev/null 2>&1; then
                x-terminal-emulator -e bash "$script_dir/oscar.sh" --menu
                return
            fi
            ;;
        Darwin)
            if command -v open >/dev/null 2>&1; then
                open -a Terminal "$script_dir/oscar.sh"
                return
            fi
            ;;
    esac
    printf 'Unable to open a terminal. Run bash "%s" from a terminal.\n' "$script_dir/oscar.sh" >&2
    exit 1
}

# Parse shell-style quoting without eval, command substitution, or expansion.
# This lets administrators enter paths containing spaces in the menu safely.
parse_menu_command() {
    local input=$1 state=plain token='' char next index=0 token_started=false
    menu_args=()
    while ((index < ${#input})); do
        char=${input:index:1}
        case "$state:$char" in
            plain:" "|plain:$'\t')
                if $token_started; then menu_args+=("$token"); token=''; token_started=false; fi
                ;;
            plain:"'") state=single; token_started=true ;;
            plain:'"') state=double; token_started=true ;;
            single:"'") state=plain ;;
            double:'"') state=plain ;;
            plain:'\'|double:'\')
                ((index += 1))
                ((index < ${#input})) || { printf 'A trailing backslash is not valid.\n' >&2; return 1; }
                next=${input:index:1}; token+=$next; token_started=true
                ;;
            *) token+=$char; token_started=true ;;
        esac
        ((index += 1))
    done
    [[ $state == plain ]] || { printf 'A quote was not closed.\n' >&2; return 1; }
    $token_started && menu_args+=("$token")
}

run_menu_command() {
    local command_name=${1:-}
    shift || true
    case "$command_name" in
        init|verify|start|stop|restart|upgrade|backup|backup-verify|backup-prune|restore|archive)
            if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
                bash "$setup_script" "$command_name" "$@"
            else
                sudo bash "$setup_script" "$command_name" "$@"
            fi
            ;;
        check|status|logs|help)
            bash "$setup_script" "$command_name" "$@"
            ;;
        exit|quit) return 2 ;;
        '') return 0 ;;
        *) printf 'Unknown command: %s\n' "$command_name" >&2; return 1 ;;
    esac
}

interactive_menu() {
    local input result
    while true; do
        clear 2>/dev/null || true
        cat <<'EOF'
OSCAR Administration
====================

Enter a command and any options. Examples:
  init
  init --hostname oscar.local --port 443
  init --hostname oscar.local --tls-san oscar-site.example.org
  start
  stop
  restart
  status
  logs --service oscar --tail 200
  logs --service postgres --follow
  check
  verify
  upgrade
  backup
  backup-verify BACKUP_ID
  restore --backup BACKUP_ID --confirm BACKUP_ID
  archive status
  archive verify
  archive hold list
  archive hold create --store-key KEY --id-scope INT --generation UUID --reason "legal hold"
  archive hold release --id UUID
  archive dry-run --store-key KEY --id-scope INT --before YYYY-MM-DDTHH:MM:SSZ
  archive purge --store-key KEY --id-scope INT --plan UUID --token TOKEN
  help

Enter exit to close this window.
EOF
        printf '\noscar> '
        IFS= read -r input || return 0
        input=${input%$'\r'}
        printf '\n'
        if parse_menu_command "$input"; then
            set +e
            run_menu_command "${menu_args[@]}"
            result=$?
            set -e
            ((result == 2)) && return 0
            ((result == 0)) || printf '\nCommand failed with exit code %s.\n' "$result"
        fi
        printf '\nPress Enter to return to the menu...'
        IFS= read -r _ || return 0
    done
}

if (($# == 0)); then
    [[ -t 0 && -t 1 ]] || open_terminal_menu
    interactive_menu
    exit 0
fi

if [[ $1 == --menu ]]; then
    shift
    interactive_menu
    exit 0
fi

exec bash "$setup_script" "$@"
