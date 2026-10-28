#!/usr/bin/env bash
set -eo pipefail

# Configuration
if [[ "$(tmux show-options -gqv @tpad-debug)" == "true" ]]; then
  LOG_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/tpad.log"
  exec >>"$LOG_FILE" 2>&1

  set -x
fi

readonly CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TPAD_SCRIPT="${CURRENT_DIR}/tpad.tmux"

get_default_config() {
  local instance="$1"
  local key="$2"

  case "$key" in
    title) printf '%s\n' "#[fg=#b8aaf0,bold] 󱂬 TPad " ;;
    dir) printf '%s\n' "$HOME" ;;
    width) printf '%s\n' "80%" ;;
    height) printf '%s\n' "80%" ;;
    style) printf '%s\n' "fg=#e5c07b" ;;
    border_lines) printf '%s\n' "rounded" ;;
    *) printf '%s\n' "" ;;
  esac
}

main() {
  check_dependencies
  case "${1:-}" in
    toggle) toggle_popup "$2" ;;
    fullscreen) toggle_fullscreen ;;
    cleanup) cleanup_sessions ;;
    "") initialize_instances ;;
    *)
      show_help
      exit 1
      ;;
  esac
}

initialize_instances() {
  tmux bind-key "C-f" run-shell "$TPAD_SCRIPT fullscreen"
  # Kill per-window pads whose tab is gone. Fixed index keeps reloads idempotent.
  tmux set-hook -g 'window-unlinked[100]' "run-shell -b \"$TPAD_SCRIPT cleanup >/dev/null 2>&1\""
  tmux set-hook -g 'session-closed[100]' "run-shell -b \"$TPAD_SCRIPT cleanup >/dev/null 2>&1\""
  # tmux popups never answer the OSC 10/11 colour queries a nested client sends on
  # attach, so the client holds a lone Esc for 500ms (ignoring escape-time). Give the
  # popup client its own TERM that tmux treats as non-VT100-like (no queries) and
  # list the features those queries would have discovered. Fixed index = idempotent.
  tmux set -s 'terminal-overrides[100]' 'tmux:clear=\E(B\E[H\E[J'
  tmux set -s 'terminal-features[100]' 'tmux:256:bpaste:ccolour:clipboard:hyperlinks:cstyle:extkeys:focus:mouse:overline:progressbar:RGB:strikethrough:sync:title:usstyle'
  tmux show-options -g | awk -v FS="-" '/^@tpad/{ print $2}' | sort -u | while read -r instance; do
    bind_key "$instance"
  done
}

toggle_popup() {
  local instance="$1"
  local current_session="$(tmux display-message -p '#{session_name}')"
  local current_window="$(tmux display-message -p '#{window_id}')"
  local current_tpad_instance="$(get_tpad_session_instance "$current_session")"
  local session="tpad_${instance}"
  local working_dir=""

  if [[ "$current_tpad_instance" == "$instance" ]]; then
    if tmux show-env -g TPAD_ZOOMED 2>/dev/null | grep -q "$current_session"; then
      tmux setenv -g -u TPAD_ZOOMED
      switch_to_tpad_parent "$current_session"
    else
      tmux detach
    fi
    return
  fi

  # Check if per-window or per-directory sessions are enabled.
  # per-window takes precedence because it scopes the panel to the origin tab.
  local per_window="$(get_config "$instance" per-window)"
  local per_dir="$(get_config "$instance" per-dir)"
  if [[ "$per_window" == "true" ]]; then
    session="$(build_window_scoped_session_name "$instance")"
  elif [[ "$per_dir" == "true" ]]; then
    local pane_dir="$(tmux display-message -p '#{pane_current_path}')"
    local git_root="$(get_git_root "$pane_dir")"

    if [[ -n "$git_root" ]]; then
      local dir_suffix="$(sanitize_dir_name "$git_root")"
      session="tpad_${instance}_${dir_suffix}"
      working_dir="$git_root"
    else
      # Fall back to using pane's current directory if not in a git repo
      local dir_suffix="$(sanitize_dir_name "$pane_dir")"
      session="tpad_${instance}_${dir_suffix}"
      working_dir="$pane_dir"
    fi
  fi

  if is_tpad_session "$current_session"; then
    tmux detach
  fi
  tmux setenv -g TPAD_PARENT_SESSION "$current_session"
  create_session_if_needed "$instance" "$session" "$working_dir"
  set_tpad_parent_metadata "$session" "$current_session" "$current_window"
  set_tab_status "$session"
  local popup_opts=()
  while IFS= read -r opt; do
    popup_opts+=("$opt")
  done < <(build_popup_options "$instance" "$working_dir")

  tmux display-popup -e TERM=tmux "${popup_opts[@]}" -E "tmux attach -t $session"
}

# Show a minimal "[1][2*]" tab bar only while the pad has more than one tab.
set_tab_status() {
  local session="$1"
  local status='#{?#{>:#{session_windows},1},on,off}'
  local hook

  tmux set -t "$session" status-style default
  tmux set -t "$session" status-format[0] '#[align=centre]#{W:[#{window_index}],[#{window_index}*]}'
  tmux set -F -t "$session" status "$status"
  for hook in window-linked window-unlinked; do
    tmux set-hook -t "$session" "$hook" "set -F status '$status'"
  done
}

# Kill per-window pads whose origin tab no longer exists. Their names end in
# the origin window id (see build_window_scoped_session_name).
cleanup_sessions() {
  local windows="$(tmux list-windows -a -F '#{window_id}')"
  local session instance
  tmux list-sessions -F '#{session_name}' | while read -r session; do
    instance="$(get_tpad_session_instance "$session")"
    [[ -n "$instance" && "$(get_config "$instance" per-window)" == "true" ]] || continue
    [[ "${session##*_}" =~ ^[0-9]+$ ]] || continue
    if ! grep -qxF "@${session##*_}" <<<"$windows"; then
      tmux kill-session -t "=$session" 2>/dev/null || true
    fi
  done
}

create_session_if_needed() {
  local instance="$1"
  local session="$2"
  local working_dir="$3"
  tmux has-session -t "$session" 2>/dev/null && return

  # Use provided working_dir or fall back to config
  local dir="${working_dir:-$(get_config "$instance" dir)}"
  local session_id="$(tmux new-session -dP -s "$session" -c "$dir" -F '#{session_id}')"
  configure_session "$instance" "$session_id"
}

configure_session() {
  local instance="$1"
  local session_id="$2"
  tmux set-option -t "$session_id" @tpad-managed "1"
  tmux set-option -t "$session_id" @tpad-instance "$instance"
  apply_session_config "$instance" "$session_id"

  local cmd="$(get_config "$instance" cmd)"
  if [[ -n "$cmd" ]]; then
    tmux send-keys -t "$session_id" "$cmd; exit" C-m
  fi
}

apply_session_config() {
  local instance="$1"
  local session_id="$2"
  tmux set -t "$session_id" default-terminal "$TERM"
  tmux set -t "$session_id" key-table "tpad_$instance"
  tmux set -t "$session_id" status off
  tmux set -t "$session_id" detach-on-destroy on
  set_opts "$instance" "$session_id"

  local prefix="$(get_config "$instance" prefix)"
  if [[ -n "$prefix" ]]; then
    tmux set -t "$session_id" prefix "$prefix"
  fi
}

set_opts() {
  local instance="$1"
  local session_id="$2"
  local opts="$(get_config "$instance" opts)"
  [[ -z "$opts" ]] && return

  while IFS=';' read -r opt; do
    [[ -n "$opt" ]] && tmux set-option -t "$session_id" $opt
  done <<<"$opts"
}

get_config() {
  local instance="$1"
  local key="$2"
  local tmux_var="@tpad-${instance}-${key}"
  local val="$(tmux show-option -gqv "$tmux_var")"

  if [[ -z "$val" ]]; then
    val="$(get_default_config "$instance" "$key")"
  fi

  printf '%s\n' "$val"
}

sanitize_session_suffix() {
  local value="$1"
  printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' '_' | sed 's/_*$//; s/^_*//'
}

is_tpad_session() {
  local session_name="$1"
  case "$session_name" in
    tpad_*) return 0 ;;
    *) return 1 ;;
  esac
}

get_tpad_session_instance() {
  local session_name="$1"
  local instance=""

  if is_tpad_session "$session_name"; then
    instance="$(tmux show-option -t "$session_name" -qv @tpad-instance 2>/dev/null || true)"
    if [[ -z "$instance" ]]; then
      instance="${session_name#tpad_}"
    fi
  fi

  printf '%s\n' "$instance"
}

build_window_scoped_session_name() {
  local instance="$1"
  local origin="$(tmux display-message -p '#{session_name}_#{window_id}')"
  printf 'tpad_%s_%s\n' "$instance" "$(sanitize_session_suffix "$origin")"
}

set_tpad_parent_metadata() {
  local session="$1"
  local parent_session="$2"
  local parent_window="$3"

  tmux set-option -t "$session" @tpad-parent-session "$parent_session"
  tmux set-option -t "$session" @tpad-parent-window "$parent_window"
}

switch_to_tpad_parent() {
  local session="$1"
  local parent_session="$(tmux show-option -t "$session" -qv @tpad-parent-session 2>/dev/null || true)"
  local parent_window="$(tmux show-option -t "$session" -qv @tpad-parent-window 2>/dev/null || true)"

  if [[ -n "$parent_session" && -n "$parent_window" ]]; then
    tmux switch-client -t "${parent_session}:${parent_window}"
  elif [[ -n "$parent_session" ]]; then
    tmux switch-client -t "$parent_session"
  else
    local env_parent="$(tmux show-env -g TPAD_PARENT_SESSION 2>/dev/null | cut -d= -f2 || true)"
    [[ -n "$env_parent" ]] && tmux switch-client -t "$env_parent"
  fi
}

copy_key_binding() {
  local source_table="$1"
  local dest_table="$2"
  local key="$3"
  local line=""
  local copied=""

  line="$(tmux list-keys -a | awk -v source="$source_table" -v key="$key" '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "-T" && $(i + 1) == source && $(i + 2) == key) {
          print
          exit
        }
      }
    }
  ')"

  [[ -z "$line" ]] && return
  copied="${line/-T $source_table/-T $dest_table}"
  printf '%s\n' "$copied" | tmux source-file -
}

bind_configured_root_keys() {
  local instance="$1"
  local keys="$(get_config "$instance" copy-root-keys)"
  local table="tpad_$instance"
  local key=""

  [[ -z "$keys" ]] && return
  for key in $keys; do
    copy_key_binding root "$table" "$key"
  done
}

bind_key() {
  local instance="$1"
  local key="$(get_config "$instance" bind)"
  [[ -z "$key" ]] && return

  local table="$(get_config "$instance" table)"

  # Mouse events always require the root table
  if [[ -z "$table" ]]; then
    case "$key" in
      Mouse* | DoubleClick* | TripleClick* | WheelUp* | WheelDown*) table="root" ;;
    esac
  fi

  if [[ -n "$table" ]]; then
    tmux bind-key -T "$table" "$key" run-shell "$TPAD_SCRIPT toggle $instance"
  else
    tmux bind-key "$key" run-shell "$TPAD_SCRIPT toggle $instance"
  fi

  bind_configured_root_keys "$instance"
  tmux bind-key -T "tpad_$instance" "$key" run-shell "$TPAD_SCRIPT toggle $instance"
}

popup_config_key() {
  case "$1" in
    T) printf '%s\n' "title" ;;
    S) printf '%s\n' "style" ;;
    s) printf '%s\n' "border_style" ;;
    b) printf '%s\n' "border_lines" ;;
    h) printf '%s\n' "height" ;;
    w) printf '%s\n' "width" ;;
    x) printf '%s\n' "pos_x" ;;
    y) printf '%s\n' "pos_y" ;;
    d) printf '%s\n' "dir" ;;
    e) printf '%s\n' "env" ;;
  esac
}

build_popup_options() {
  local instance="$1"
  local working_dir="$2"
  local opt key val dir_name

  for opt in T S s b h w x y d e; do
    key="$(popup_config_key "$opt")"
    val=""
    # Use provided working_dir for the dir option if available
    if [[ "$opt" == "d" && -n "$working_dir" ]]; then
      val="$working_dir"
    elif [[ "$opt" == "T" && -n "$working_dir" ]]; then
      # Append directory name to title if per-dir is enabled
      val="$(get_config "$instance" "$key")"
      dir_name="$(basename "$working_dir")"
      val="${val% } [${dir_name}]  "
    else
      val="$(get_config "$instance" "$key")"
    fi
    if [[ -n "$val" ]]; then
      echo "-${opt}"
      echo "${val}"
    fi
  done
}

check_dependencies() {
  if ! command -v tmux &>/dev/null; then
    echo "Error: tmux is required but not installed" >&2
    exit 1
  fi
}

get_git_root() {
  local pane_dir="$1"
  if [[ -d "$pane_dir/.git" ]]; then
    echo "$pane_dir"
    return
  fi

  (cd "$pane_dir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || echo ""
}

sanitize_dir_name() {
  local dir="$1"
  # Get the basename and convert to safe session name suffix
  basename "$dir" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' '_' | sed 's/_*$//'
}

toggle_fullscreen() {
  local current_session="$(tmux display-message -p '#{session_name}')"
  local instance="$(get_tpad_session_instance "$current_session")"

  if [[ -z "$instance" ]]; then
    return
  fi

  local zoomed_session="$(tmux show-env -g TPAD_ZOOMED 2>/dev/null | cut -d= -f2 || true)"
  if [[ "$zoomed_session" == "$current_session" ]]; then
    # Exiting fullscreen mode - clear fullscreen settings and restore config
    tmux setenv -g -u TPAD_ZOOMED
    tmux set -u -t "$current_session" status-left
    tmux set -u -t "$current_session" status-right
    tmux set -u -t "$current_session" status-justify
    tmux set -u -t "$current_session" status-position
    tmux set -u -t "$current_session" status-style
    apply_session_config "$instance" "$current_session"
    switch_to_tpad_parent "$current_session"
    toggle_popup "$instance"
  else
    # Entering fullscreen mode
    tmux setenv -g TPAD_ZOOMED "$current_session"
    # Fullscreen uses the normal status line; the tab bar returns on exit.
    tmux set-hook -u -t "$current_session" window-linked
    tmux set-hook -u -t "$current_session" window-unlinked
    tmux set -u -t "$current_session" status-format
    tmux detach
    tmux switch-client -t "$current_session"

    local title="$(get_config "$instance" title)"
    tmux set -t "$current_session" status on
    tmux set -t "$current_session" status-justify centre
    tmux set -t "$current_session" status-position top
    tmux set -t "$current_session" status-left ""
    tmux set -t "$current_session" status-right "${title} [FULLSCREEN]"
    tmux set -t "$current_session" status-style "bg=terminal,fg=terminal"
  fi
}

show_help() {
  cat <<EOF
TPad - Tmux Popup Manager

Usage:
  tpad.tmux [command]

Commands:
  (no command)  Initialize all configured instances
  toggle        Toggle a popup instance
  cleanup       Kill per-window pads whose tmux tab is gone
EOF
}

main "$@"
