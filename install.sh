#!/usr/bin/env bash
# smux — one-command tmux setup
set -euo pipefail

VERSION="2.1.0"
REPO="yangyang0507/smux"
BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
SMUX_DIR="$HOME/.smux"
BIN_DIR="$SMUX_DIR/bin"
BACKUP_DIR="$SMUX_DIR/backups"
TMUX_XDG_DIR="$HOME/.config/tmux"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { printf "${GREEN}[smux]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[smux]${NC} %s\n" "$*"; }
error() { printf "${RED}[smux]${NC} %s\n" "$*" >&2; exit 1; }
doctor_ok() { printf "[ok]   %s\n" "$*"; }
doctor_warn() { printf "[warn] %s\n" "$*"; }
doctor_fail() { printf "[fail] %s\n" "$*"; }
doctor_info() { printf "[info] %s\n" "$*"; }

# --- OS / package manager detection ---

detect_os() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)  echo "linux" ;;
    *)      error "Unsupported OS: $(uname -s)" ;;
  esac
}

detect_pkg_manager() {
  if command -v brew >/dev/null 2>&1; then echo "brew"
  elif command -v apt-get >/dev/null 2>&1; then echo "apt"
  elif command -v dnf >/dev/null 2>&1; then echo "dnf"
  elif command -v pacman >/dev/null 2>&1; then echo "pacman"
  elif command -v apk >/dev/null 2>&1; then echo "apk"
  else echo "unknown"
  fi
}

pkg_install() {
  local pkg="$1"
  local mgr
  mgr=$(detect_pkg_manager)
  info "Installing $pkg via $mgr..."
  case "$mgr" in
    brew)   brew install "$pkg" ;;
    apt)    sudo apt-get update -qq && sudo apt-get install -y -qq "$pkg" ;;
    dnf)    sudo dnf install -y -q "$pkg" ;;
    pacman) sudo pacman -S --noconfirm "$pkg" ;;
    apk)    sudo apk add "$pkg" ;;
    *)      error "No supported package manager found. Install $pkg manually and re-run." ;;
  esac
}

# --- Helpers ---

check_tmux_version() {
  local ver
  ver=$(tmux -V 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' || echo "0.0")
  local major minor
  major=$(echo "$ver" | cut -d. -f1)
  minor=$(echo "$ver" | cut -d. -f2)
  if (( major < 3 || (major == 3 && minor < 2) )); then
    warn "tmux $ver detected. Version 3.2+ recommended for full visual features."
  fi
}

backup_existing() {
  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$BACKUP_DIR"

  # Check XDG location
  if [[ -f "$TMUX_XDG_DIR/tmux.conf" && ! -L "$TMUX_XDG_DIR/tmux.conf" ]]; then
    cp "$TMUX_XDG_DIR/tmux.conf" "$BACKUP_DIR/tmux.conf.$ts"
    info "Backed up ~/.config/tmux/tmux.conf → ~/.smux/backups/tmux.conf.$ts"
  fi

  # Check legacy location
  if [[ -f "$HOME/.tmux.conf" ]]; then
    cp "$HOME/.tmux.conf" "$BACKUP_DIR/tmux.conf.legacy.$ts"
    info "Backed up ~/.tmux.conf → ~/.smux/backups/tmux.conf.legacy.$ts"
  fi
}

ensure_path() {
  local rc_file=""
  case "${SHELL:-/bin/bash}" in
    */zsh)  rc_file="$HOME/.zshrc" ;;
    */bash) rc_file="$HOME/.bashrc" ;;
    *)      rc_file="$HOME/.profile" ;;
  esac

  local path_line='export PATH="$HOME/.smux/bin:$PATH"'

  # Write to rc file if not already present
  if [[ -f "$rc_file" ]] && ! grep -qF '.smux/bin' "$rc_file"; then
    info "Adding ~/.smux/bin to PATH in $rc_file"
    echo "" >> "$rc_file"
    echo "# smux" >> "$rc_file"
    echo "$path_line" >> "$rc_file"
  fi

  # Export into current shell if not already in PATH
  if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    export PATH="$BIN_DIR:$PATH"
  fi
}

download() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url"
  else
    error "Neither curl nor wget found. Install one and re-run."
  fi
}

# ================================================================
# smux v2 — declarative pane layout and lifecycle management
# ================================================================

# --- Text utilities ---

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

repeat_char() {
  local ch="$1" n="$2" out=""
  while (( n-- > 0 )); do out="${out}${ch}"; done
  printf '%s' "$out"
}

valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]]
}

find_project_root() {
  local dir="$PWD"
  while :; do
    if [[ -f "$dir/.smux" ]]; then
      # Allow $HOME/.smux only when running from $HOME itself (explicit workspace).
      # When running from a subdirectory, walking up to $HOME is an implicit fallback — reject.
      if [[ "$dir" == "$HOME" && "$PWD" != "$HOME" ]]; then
        error "Refusing to use ~/.smux as an implicit fallback from $PWD. Run from ~ to use it as a workspace, or create .smux in this project."
      fi
      echo "$dir"
      return
    fi
    [[ "$dir" == "/" ]] && error "No .smux found from $PWD upward. Run 'smux init' to create one."
    dir=$(dirname "$dir")
  done
}

find_project_root_safe() {
  local dir="$PWD"
  while :; do
    if [[ -f "$dir/.smux" ]]; then
      if [[ "$dir" == "$HOME" && "$PWD" != "$HOME" ]]; then
        echo "Refusing to use ~/.smux as an implicit fallback from $PWD. Run from ~ to use it as a workspace, or create .smux in this project." >&2
        return 2
      fi
      echo "$dir"
      return 0
    fi
    if [[ "$dir" == "/" ]]; then
      echo "No .smux found from $PWD upward. Run 'smux init' to create one." >&2
      return 1
    fi
    dir=$(dirname "$dir")
  done
}

session_name_for() {
  local project="$1" name="${2:-}"
  [[ -n "$name" ]] || name=$(basename "$project")
  valid_name "$name" || error "Invalid session name '$name'. Session names must match [A-Za-z0-9_.-]+. Use 'smux start -n my-project'."
  echo "$name"
}

session_project() {
  tmux show-options -t "$1" -qv @smux_project 2>/dev/null || true
}

require_smux_session() {
  local session="$1" project
  tmux has-session -t "$session" 2>/dev/null || error "No tmux session named '$session'. Run 'smux status' to list smux-managed sessions."
  project=$(session_project "$session")
  [[ -n "$project" ]] || error "Session '$session' already exists but is not managed by smux. Choose another name with '-n', or handle it manually in tmux."
}

layout_line() {
  local file="$1" line clean found="" count=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    clean=$(trim "$line")
    [[ -z "$clean" || "${clean:0:1}" == "#" ]] && continue
    (( count += 1 ))
    [[ $count -eq 1 ]] || error ".smux has multiple layout lines. .smux requires exactly one layout line."
    found="$clean"
  done < "$file"
  [[ -n "$found" ]] || error ".smux is empty. .smux requires exactly one layout line. Run 'smux init' for examples."
  echo "$found"
}

# Quote-aware string splitter.
# Splits $1 by delimiter $2, but ignores delimiters inside double-quoted regions.
# Each segment is printed on its own line (suitable for 'while read' consumption).
# Returns 2 if quotes are unbalanced.
split_aware() {
  local s="$1" delim="$2" inq=0 esc=0 buf="" ch i
  for (( i=0; i<${#s}; i++ )); do
    ch="${s:i:1}"
    if (( esc )); then buf="${buf}${ch}"; esc=0; continue; fi
    if [[ "$ch" == "\\" && $inq -eq 1 ]]; then buf="${buf}${ch}"; esc=1; continue; fi
    if [[ "$ch" == '"' ]]; then
      (( inq = 1 - inq ))
      buf="${buf}${ch}"
      continue
    fi
    if [[ "$ch" == "$delim" && $inq -eq 0 ]]; then
      printf '%s\n' "$buf"
      buf=""
    else
      buf="${buf}${ch}"
    fi
  done
  (( inq == 0 )) || return 2
  printf '%s\n' "$buf"
}

quote_balanced() {
  local s="$1" inq=0 esc=0 ch i
  for (( i=0; i<${#s}; i++ )); do
    ch="${s:i:1}"
    if (( esc )); then esc=0; continue; fi
    if [[ "$ch" == "\\" && $inq -eq 1 ]]; then esc=1; continue; fi
    [[ "$ch" == '"' ]] && (( inq = 1 - inq ))
  done
  (( inq == 0 ))
}

unquote_command() {
  local s
  s=$(trim "$1")
  if [[ "${s:0:1}" == '"' && "${s:${#s}-1:1}" == '"' ]]; then
    s="${s:1:${#s}-2}"
    s="${s//\\\\/\\}"
    s="${s//\\\"/\"}"
  fi
  printf '%s' "$s"
}

# --- Parser state: populated by parse_layout(), consumed by start_layout() and preview ---
# Arrays are indexed by global pane index (0..PANE_COUNT-1).
# COL_START[c] = first pane index in column c; COL_COUNT[c] = number of panes in column c.
PANE_LABELS=()
PANE_COMMANDS=()
PANE_COLS=()
COL_START=()
COL_COUNT=()
COL_WIDTH=()
PANE_COUNT=0
COL_COUNT_TOTAL=0

# Parse a .smux layout line into the global pane/column arrays.
# Splits by '|' to get columns, then by ',' to get panes within each column.
# Each cell: LABEL [COMMAND].  Label is the first [A-Za-z0-9_.-]+ word;
# everything after is the command (may be empty = shell pane).
parse_layout() {
  local line="$1" col cell label cmd rest col_start col_count
  quote_balanced "$line" || error "Unclosed quote in .smux layout: $line. Fix the quote, then run 'smux start --dry-run' to verify."
  PANE_LABELS=(); PANE_COMMANDS=(); PANE_COLS=(); COL_START=(); COL_COUNT=()
  PANE_COUNT=0; COL_COUNT_TOTAL=0
  while IFS= read -r col; do
    col=$(trim "$col")
    [[ -n "$col" ]] || error "Empty column in .smux layout: $line. Remove the extra '|' or add a label."
    col_start=$PANE_COUNT
    col_count=0
    while IFS= read -r cell; do
      cell=$(trim "$cell")
      [[ -n "$cell" ]] || error "Empty pane in .smux layout: $line. Remove the extra comma or add a label."
      label="${cell%%[[:space:]]*}"
      rest="${cell#"$label"}"
      cmd=$(unquote_command "$rest")
      valid_name "$label" || error "Invalid label '$label'. Labels must match [A-Za-z0-9_.-]+. Use a label like 'test-runner npm test'."
      PANE_LABELS[$PANE_COUNT]="$label"
      PANE_COMMANDS[$PANE_COUNT]="$cmd"
      PANE_COLS[$PANE_COUNT]="$COL_COUNT_TOTAL"
      (( PANE_COUNT += 1, col_count += 1 ))
    done < <(split_aware "$col" ",")
    COL_START[$COL_COUNT_TOTAL]="$col_start"
    COL_COUNT[$COL_COUNT_TOTAL]="$col_count"
    (( COL_COUNT_TOTAL += 1 ))
  done < <(split_aware "$line" "|")
}

display_cmd() {
  local cmd="$1" sh
  if [[ -n "$cmd" ]]; then
    echo "$cmd"
  else
    sh="${SHELL##*/}"
    [[ -n "$sh" ]] || sh="shell"
    echo "($sh)"
  fi
}

print_plan() {
  local session="$1" project="$2" i labelw=10 d
  for (( i=0; i<PANE_COUNT; i++ )); do
    ((${#PANE_LABELS[$i]} > labelw)) && labelw=${#PANE_LABELS[$i]}
  done
  echo "session: $session"
  echo "project: $project"
  echo "panes:"
  for (( i=0; i<PANE_COUNT; i++ )); do
    d=$(display_cmd "${PANE_COMMANDS[$i]}")
    printf "  %-*s  %s\n" "$labelw" "${PANE_LABELS[$i]}" "$d"
  done
}

fit_text() {
  local s="$1" w="$2" l pad left right
  if (( ${#s} > w )); then s="${s:0:$((w-1))}…"; fi
  l=${#s}; pad=$((w-l)); left=$((pad/2)); right=$((pad-left))
  printf '%s%s%s' "$(repeat_char ' ' "$left")" "$s" "$(repeat_char ' ' "$right")"
}

preview_line_for() {
  local col="$1" row="$2" height="$3" width="$4" n start mid p off idx text=""
  n="${COL_COUNT[$col]}"; start="${COL_START[$col]}"
  if (( n == 1 )); then
    mid=$((height/2))
    (( row == mid-1 )) && text="${PANE_LABELS[$start]}"
    (( row == mid )) && text=$(display_cmd "${PANE_COMMANDS[$start]}")
  else
    for (( p=0; p<n; p++ )); do
      off=$((p*3)); idx=$((start+p))
      (( row == off )) && text="${PANE_LABELS[$idx]}"
      (( row == off+1 )) && text=$(display_cmd "${PANE_COMMANDS[$idx]}")
      if (( p < n-1 && row == off+2 )); then
        repeat_char "─" "$width"
        return
      fi
    done
  fi
  fit_text "$text" "$width"
}

print_preview() {
  local c i width max_rows=0 row
  for (( c=0; c<COL_COUNT_TOTAL; c++ )); do
    width=10
    for (( i=0; i<COL_COUNT[$c]; i++ )); do
      local idx=$((COL_START[$c]+i)) d
      d=$(display_cmd "${PANE_COMMANDS[$idx]}")
      ((${#PANE_LABELS[$idx]}+2 > width)) && width=$((${#PANE_LABELS[$idx]}+2))
      ((${#d}+2 > width)) && width=$((${#d}+2))
    done
    (( width > 24 )) && width=24
    COL_WIDTH[$c]="$width"
    local rows=$((COL_COUNT[$c]*2 + COL_COUNT[$c] - 1))
    (( rows > max_rows )) && max_rows=$rows
  done
  # --- Draw top border: ┌──┬──┬──┐ ---
  printf '┌'
  for (( c=0; c<COL_COUNT_TOTAL; c++ )); do
    repeat_char "─" "${COL_WIDTH[$c]}"
    (( c == COL_COUNT_TOTAL-1 )) && printf '┐' || printf '┬'
  done
  printf '\n'
  # --- Draw rows ---
  for (( row=0; row<max_rows; row++ )); do
    printf '│'
    for (( c=0; c<COL_COUNT_TOTAL; c++ )); do
      preview_line_for "$c" "$row" "$max_rows" "${COL_WIDTH[$c]}"
      printf '│'
    done
    printf '\n'
  done
  # --- Draw bottom border: └──┴──┴──┘ ---
  printf '└'
  for (( c=0; c<COL_COUNT_TOTAL; c++ )); do
    repeat_char "─" "${COL_WIDTH[$c]}"
    (( c == COL_COUNT_TOTAL-1 )) && printf '┘' || printf '┴'
  done
  printf '\n'
}

# Type a command into a pane (literal mode) and press Enter.
# No-op if command is empty.
send_command_to_pane() {
  local pane="$1" cmd="$2"
  [[ -n "$cmd" ]] || return 0
  tmux send-keys -t "$pane" -l -- "$cmd"
  tmux send-keys -t "$pane" Enter
}

# Create a tmux session from parsed layout data.
# Column-first creation order:
#   1. new-session (col 0)
#   2. split-window -h for each additional column, target = previous column's top pane
#   3. select-layout even-horizontal to equalize column widths
#   4. split-window -v within each column, using percentages for roughly equal heights
#   5. set @smux_label + @name on each pane, then send the startup command
start_layout() {
  local session="$1" project="$2" replace="$3" detached="$4" marker
  # --- Duplicate / safety check ---
  if tmux has-session -t "$session" 2>/dev/null; then
    marker=$(session_project "$session")
    [[ -n "$marker" ]] || error "Session '$session' already exists but is not managed by smux. Choose another name with '-n', or handle it manually in tmux."
    (( replace )) || error "Session '$session' already exists and is smux-managed. Use 'smux attach -n $session', or 'smux start --replace' to rebuild it."
    tmux kill-session -t "$session"
  fi
  local pane col idx j k pct prev
  PANE_IDS=(); COL_TOP=()
  # --- Phase 1: create all columns horizontally ---
  pane=$(tmux new-session -d -s "$session" -c "$project" -P -F '#{pane_id}')
  PANE_IDS[0]="$pane"; COL_TOP[0]="$pane"
  tmux set-option -t "$session" @smux_project "$project" >/dev/null
  for (( col=1; col<COL_COUNT_TOTAL; col++ )); do
    prev="${COL_TOP[$((col-1))]}"                              # target = previous column's top pane
    pane=$(tmux split-window -h -t "$prev" -c "$project" -P -F '#{pane_id}')
    idx="${COL_START[$col]}"
    PANE_IDS[$idx]="$pane"
    COL_TOP[$col]="$pane"
  done
  tmux select-layout -t "$session:0" even-horizontal >/dev/null 2>&1 || true
  # --- Phase 2: stack panes vertically within each column ---
  for (( col=0; col<COL_COUNT_TOTAL; col++ )); do
    k="${COL_COUNT[$col]}"
    prev="${COL_TOP[$col]}"
    for (( j=1; j<k; j++ )); do
      pct=$((100*(k-j)/(k-j+1)))                                # split remaining space proportionally
      (( pct < 1 )) && pct=50
      pane=$(tmux split-window -v -p "$pct" -t "$prev" -c "$project" -P -F '#{pane_id}')
      idx=$((COL_START[$col]+j))
      PANE_IDS[$idx]="$pane"
      prev="$pane"
    done
  done
  # --- Phase 3: label and launch ---
  for (( idx=0; idx<PANE_COUNT; idx++ )); do
    pane="${PANE_IDS[$idx]}"
    tmux set-option -p -t "$pane" @smux_label "${PANE_LABELS[$idx]}" >/dev/null
    tmux set-option -p -t "$pane" @name "${PANE_LABELS[$idx]}" >/dev/null
    send_command_to_pane "$pane" "${PANE_COMMANDS[$idx]}"
  done
  (( detached )) || {
    if [[ -n "${TMUX:-}" ]]; then tmux switch-client -t "$session"; else tmux attach -t "$session"; fi
  }
}

# ================================================================
# CLI command handlers
# ================================================================

cmd_install() {
  local os
  os=$(detect_os)
  info "Installing smux ($os)..."

  # 1. Install tmux if missing
  if ! command -v tmux >/dev/null 2>&1; then
    info "tmux not found. Installing..."
    if [[ "$os" == "macos" ]] && ! command -v brew >/dev/null 2>&1; then
      error "Homebrew is required to install tmux on macOS. Install it from https://brew.sh and re-run."
    fi
    pkg_install tmux
  fi
  check_tmux_version

  # 2. Install clipboard tool on Linux if missing
  if [[ "$os" == "linux" ]]; then
    if ! command -v xclip >/dev/null 2>&1 && ! command -v xsel >/dev/null 2>&1; then
      info "No clipboard tool found. Installing xclip..."
      pkg_install xclip
    fi
  fi

  # 3. Create directories
  mkdir -p "$SMUX_DIR" "$BIN_DIR" "$BACKUP_DIR"

  # 4. Back up existing config
  backup_existing

  # 5. Download tmux.conf
  info "Downloading tmux.conf..."
  download "$BASE_URL/.tmux.conf" "$SMUX_DIR/tmux.conf"

  # 6. Symlink tmux config
  mkdir -p "$TMUX_XDG_DIR"
  ln -sf "$SMUX_DIR/tmux.conf" "$TMUX_XDG_DIR/tmux.conf"

  # 7. Download tmux-bridge
  info "Downloading tmux-bridge..."
  download "$BASE_URL/scripts/tmux-bridge" "$BIN_DIR/tmux-bridge"
  chmod +x "$BIN_DIR/tmux-bridge"

  # 8. Save smux CLI
  info "Installing smux CLI..."
  download "$BASE_URL/install.sh" "$BIN_DIR/smux"
  chmod +x "$BIN_DIR/smux"

  # 9. Ensure PATH
  ensure_path

  # 10. Reload tmux if running
  if tmux list-sessions &>/dev/null; then
    tmux source-file "$SMUX_DIR/tmux.conf" 2>/dev/null && info "Reloaded tmux config." || true
  fi

  # 11. Done
  echo ""
  printf "${GREEN}${BOLD}smux installed!${NC}\n"
  echo ""
  echo "  Config:       ~/.smux/tmux.conf"
  echo "  tmux-bridge:  ~/.smux/bin/tmux-bridge"
  echo "  smux CLI:     ~/.smux/bin/smux"
  echo ""
  echo "  Run 'smux help' for commands."
  if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    echo ""
    warn "Restart your shell or run: export PATH=\"\$HOME/.smux/bin:\$PATH\""
  fi
}

cmd_update() {
  info "Updating smux..."

  mkdir -p "$SMUX_DIR" "$BIN_DIR" "$BACKUP_DIR"
  backup_existing

  info "Downloading tmux.conf..."
  download "$BASE_URL/.tmux.conf" "$SMUX_DIR/tmux.conf"

  info "Downloading tmux-bridge..."
  download "$BASE_URL/scripts/tmux-bridge" "$BIN_DIR/tmux-bridge"
  chmod +x "$BIN_DIR/tmux-bridge"

  # Download to a temp file to avoid overwriting the running script.
  # If we overwrite $BIN_DIR/smux in-place while bash is executing it,
  # bash may seek into the new file and execute heredoc content as commands.
  info "Updating smux CLI..."
  download "$BASE_URL/install.sh" "$BIN_DIR/smux.new"
  chmod +x "$BIN_DIR/smux.new"
  mv "$BIN_DIR/smux.new" "$BIN_DIR/smux"

  if tmux list-sessions &>/dev/null; then
    tmux source-file "$SMUX_DIR/tmux.conf" 2>/dev/null && info "Reloaded tmux config." || true
  fi

  info "Update complete. Restarting..."
  exec "$BIN_DIR/smux" version
}

cmd_uninstall() {
  info "Uninstalling smux..."

  # Remove symlink
  if [[ -L "$TMUX_XDG_DIR/tmux.conf" ]]; then
    rm "$TMUX_XDG_DIR/tmux.conf"
    info "Removed symlink ~/.config/tmux/tmux.conf"
  fi

  # Check for backups to restore
  local latest_backup
  latest_backup=$(ls -t "$BACKUP_DIR"/tmux.conf.* 2>/dev/null | head -1 || true)
  if [[ -n "$latest_backup" ]]; then
    info "Restoring backup: $latest_backup"
    mkdir -p "$TMUX_XDG_DIR"
    cp "$latest_backup" "$TMUX_XDG_DIR/tmux.conf"
  fi

  # Remove smux directory
  rm -rf "$SMUX_DIR"
  info "Removed ~/.smux/"

  echo ""
  printf "${GREEN}${BOLD}smux uninstalled.${NC}\n"
  echo ""
  echo "  Note: You may want to remove the PATH line from your shell rc file:"
  echo "    export PATH=\"\$HOME/.smux/bin:\$PATH\""
}

cmd_start() {
  local name="" detached=0 replace=0 dry_run=0 preview=0 project session line
  while (($#)); do
    case "$1" in
      -n) [[ $# -ge 2 ]] || error "-n requires a session name."; name="$2"; shift 2 ;;
      -d) detached=1; shift ;;
      --replace) replace=1; shift ;;
      --dry-run) dry_run=1; shift ;;
      --preview) preview=1; dry_run=1; shift ;;
      *) error "Unknown start option: $1" ;;
    esac
  done
  command -v tmux >/dev/null 2>&1 || error "tmux not found."
  project=$(find_project_root)
  session=$(session_name_for "$project" "$name")
  line=$(layout_line "$project/.smux")
  parse_layout "$line"
  if (( dry_run )); then
    if (( preview )); then
      echo "session: $session"
      echo "project: $project"
      echo ""
      print_preview
      echo ""
      print_plan "$session" "$project" | sed '1,2d'
    else
      print_plan "$session" "$project"
    fi
    return
  fi
  start_layout "$session" "$project" "$replace" "$detached"
}

cmd_stop() {
  local name="" project session
  while (($#)); do
    case "$1" in
      -n) [[ $# -ge 2 ]] || error "-n requires a session name."; name="$2"; shift 2 ;;
      *) error "Unknown stop option: $1" ;;
    esac
  done
  if [[ -z "$name" ]]; then
    project=$(find_project_root)
    session=$(session_name_for "$project" "")
  else
    session=$(session_name_for "$PWD" "$name")
  fi
  require_smux_session "$session"
  tmux kill-session -t "$session"
  info "Stopped smux session '$session'."
}

cmd_attach() {
  local name="" project session
  while (($#)); do
    case "$1" in
      -n) [[ $# -ge 2 ]] || error "-n requires a session name."; name="$2"; shift 2 ;;
      *) error "Unknown attach option: $1" ;;
    esac
  done
  if [[ -z "$name" ]]; then
    project=$(find_project_root)
    session=$(session_name_for "$project" "")
  else
    session=$(session_name_for "$PWD" "$name")
  fi
  tmux has-session -t "$session" 2>/dev/null || error "No tmux session named '$session'."
  if [[ -n "${TMUX:-}" ]]; then tmux switch-client -t "$session"; else tmux attach -t "$session"; fi
}

cmd_status() {
  command -v tmux >/dev/null 2>&1 || error "tmux not found."
  printf "%-12s %-28s %-7s %s\n" "SESSION" "PROJECT" "PANES" "LABELS"
  { tmux list-sessions -F '#{session_name}|#{@smux_project}' 2>/dev/null || true; } |
  while IFS='|' read -r session project; do
    [[ -n "$project" ]] || continue
    local panes labels short_project
    panes=$(tmux list-panes -t "$session" -F '#{pane_id}' 2>/dev/null | wc -l | tr -d ' ')
    labels=$(tmux list-panes -t "$session" -F '#{@smux_label}' 2>/dev/null | awk 'NF { printf "%s%s", sep, $0; sep=", " }')
    short_project="${project/#$HOME/~}"
    printf "%-12s %-28s %-7s %s\n" "$session" "$short_project" "$panes" "${labels:--}"
  done
}

cmd_init() {
  local force=0 layout=""
  while (($#)); do
    case "$1" in
      --force) force=1; shift ;;
      --help|-h) layout=""; shift; break ;;
      --*) error "Unknown init option: $1" ;;
      *) layout="${layout:+$layout }$1"; shift ;;
    esac
  done

  if [[ -z "$layout" ]]; then
    cat <<'INIT_HELP'
Usage: smux init [--force] '<layout>'

Common layouts:
  Two agents:
    codex codex | claude claude
  Agent + shell:
    codex codex | cmd
  Writer + tests:
    writer codex, tester npm test
  Full workflow:
    cmd | writer codex, tester "npm test" | reviewer claude

Syntax:
  LABEL COMMAND    pane labeled LABEL running COMMAND
  LABEL            empty shell pane (e.g. `cmd`)
  |                split columns
  ,                stack within column

  Tip: `cmd` is just a label, not a required keyword.

Examples:
  smux init 'codex codex | claude claude'
  smux init 'cmd | writer codex, tester "npm test" | reviewer claude'

Then: smux start --preview  (or)  smux start
INIT_HELP
    return 0
  fi

  parse_layout "$layout"

  if [[ -f ".smux" ]] && (( ! force )); then
    error ".smux already exists. Use 'smux init --force <layout>' to overwrite."
  fi

  {
    echo "# | split columns     , stack within column"
    echo "# Each cell: LABEL COMMAND (or just LABEL for empty shell)"
    echo ""
    echo "$layout"
  } > .smux

  info "Created .smux:"
  cat .smux
  echo ""
  info "Next: smux start --preview  (or)  smux start"
}

cmd_doctor() {
  echo "smux doctor"

  local tmux_version="" major=0 minor=0 sessions="" session_count=0
  if command -v tmux >/dev/null 2>&1; then
    tmux_version=$(tmux -V 2>/dev/null || true)
    doctor_ok "tmux installed: ${tmux_version:-unknown version}"
    local ver
    ver=$(printf '%s' "$tmux_version" | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "0.0")
    major=$(echo "$ver" | cut -d. -f1)
    minor=$(echo "$ver" | cut -d. -f2)
    if (( major < 3 || (major == 3 && minor < 2) )); then
      doctor_warn "tmux $ver detected; tmux 3.2+ is recommended."
    else
      doctor_ok "tmux version is supported."
    fi
  else
    doctor_fail "tmux not found. Install tmux, then run 'smux doctor' again."
  fi

  if command -v tmux >/dev/null 2>&1; then
    if sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null); then
      session_count=$(printf '%s\n' "$sessions" | awk 'NF { count++ } END { print count+0 }')
      doctor_ok "tmux server reachable (${session_count} sessions)"
    else
      doctor_warn "tmux server has no running sessions, or is not reachable yet. Start tmux or run 'smux start'."
    fi
  fi

  local smux_path bridge_path smux_version
  smux_path=$(command -v smux 2>/dev/null || true)
  if [[ -n "$smux_path" ]]; then
    smux_version=$(smux version 2>/dev/null || true)
    if [[ "$smux_version" == "smux $VERSION" ]]; then
      doctor_ok "smux CLI: $smux_path ${smux_version#smux }"
    else
      doctor_warn "smux CLI: $smux_path ${smux_version#smux }; this script is $VERSION. Fix: smux update"
    fi
  else
    doctor_warn "smux CLI not found in PATH. Run: export PATH=\"\$HOME/.smux/bin:\$PATH\""
  fi

  bridge_path=$(command -v tmux-bridge 2>/dev/null || true)
  if [[ -n "$bridge_path" && -x "$bridge_path" ]]; then
    doctor_ok "tmux-bridge: $bridge_path"
  else
    doctor_fail "tmux-bridge not found in PATH. Run 'smux install' or update PATH."
  fi

  if command -v tmux >/dev/null 2>&1; then
    local border_format
    border_format=$(tmux show-options -gqv pane-border-format 2>/dev/null || true)
    if [[ "$border_format" == *"@name"* ]]; then
      doctor_ok "tmux config loaded (pane labels enabled)"
    else
      doctor_warn "tmux config may not be loaded; pane-border-format does not reference @name. Fix: tmux source-file ~/.smux/tmux.conf"
    fi
  fi

  local project="" project_err="" line="" session="" parse_err=""
  project_err=$(mktemp "${TMPDIR:-/tmp}/smux-doctor-project.XXXXXX")
  if project=$(find_project_root_safe 2>"$project_err"); then
    doctor_ok "project .smux: $project/.smux"
    if line=$(layout_line "$project/.smux" 2>"$project_err") &&
       parse_err=$( (parse_layout "$line"; printf '%s|%s' "$PANE_COUNT" "$COL_COUNT_TOTAL") 2>"$project_err"); then
      doctor_ok "layout parses: ${parse_err%%|*} panes, ${parse_err##*|} columns"
      if session=$(session_name_for "$project" "" 2>/dev/null); then
        if tmux has-session -t "$session" 2>/dev/null; then
          local marker
          marker=$(session_project "$session")
          if [[ -n "$marker" ]]; then
            doctor_info "default session '$session' already exists and is smux-managed. Use 'smux attach -n $session'."
          else
            doctor_warn "default session '$session' exists but is not managed by smux. Use 'smux start -n <name>' or handle it manually in tmux."
          fi
        else
          doctor_ok "default session '$session' is available"
        fi
      else
        doctor_warn "default session name is invalid. Use 'smux start -n my-project'."
      fi
    else
      doctor_fail "project .smux does not parse. Run 'smux start --dry-run' for details."
    fi
  else
    local msg
    msg=$(cat "$project_err" 2>/dev/null || true)
    doctor_warn "${msg:-project .smux not found. Run 'smux init' to create one.}"
  fi
  rm -f "$project_err"

  if command -v tmux >/dev/null 2>&1 && tmux list-sessions >/dev/null 2>&1; then
    local found=0 sess managed_project panes missing labels short_project
    while IFS='|' read -r sess managed_project; do
      [[ -n "$managed_project" ]] || continue
      found=1
      panes=$(tmux list-panes -t "$sess" -F '#{pane_id}' 2>/dev/null | wc -l | tr -d ' ')
      missing=$(tmux list-panes -t "$sess" -F '#{@smux_label}' 2>/dev/null | awk 'NF == 0 { count++ } END { print count+0 }')
      labels=$(tmux list-panes -t "$sess" -F '#{@smux_label}' 2>/dev/null | awk 'NF { printf "%s%s", sep, $0; sep=", " }')
      short_project="${managed_project/#$HOME/~}"
      if (( missing > 0 )); then
        doctor_warn "smux session '$sess': $panes panes, $missing missing labels, project $short_project"
      else
        doctor_info "smux session '$sess': $panes panes (${labels:-no labels}), project $short_project"
      fi
    done < <(tmux list-sessions -F '#{session_name}|#{@smux_project}' 2>/dev/null)
    (( found )) || doctor_info "smux sessions: none"
  fi
}

cmd_version() {
  echo "smux $VERSION"
}

cmd_help() {
  cat <<'EOF'
smux — one-command tmux setup

Usage: smux <command>

Commands:
  install     Install smux (tmux config + tmux-bridge)
  update      Update to the latest version
  uninstall   Remove smux and restore previous config
  init        Create a .smux layout file
  start       Start a .smux tmux workspace
  stop        Stop a smux-managed session
  attach      Attach to a session
  status      List smux-managed sessions
  doctor      Diagnose smux and tmux setup
  version     Print version
  help        Show this help

Workspace:
  smux init [--force] '<layout>'
  smux start [-n <name>] [-d] [--replace] [--dry-run] [--preview]
  smux stop  [-n <name>]
  smux attach [-n <name>]

Files:
  ~/.smux/tmux.conf          tmux configuration
  ~/.smux/bin/tmux-bridge    cross-pane communication CLI
  ~/.smux/bin/smux           this CLI
  ~/.smux/backups/           config backups
EOF
}

# --- Main ---

# When invoked as the installed `smux` CLI, default to help (no-op).
# When invoked as install.sh (curl-pipe or `bash install.sh`), default to install.
_smux_script="${BASH_SOURCE[0]:-}"
if [[ -n "$_smux_script" && "$(basename "$_smux_script")" == "smux" ]]; then
  _smux_default="help"
else
  _smux_default="install"
fi

case "${1:-$_smux_default}" in
  install)                    [[ $# -gt 0 ]] && shift; cmd_install "$@" ;;
  update)                     [[ $# -gt 0 ]] && shift; cmd_update "$@" ;;
  uninstall|remove)           [[ $# -gt 0 ]] && shift; cmd_uninstall "$@" ;;
  init)                       [[ $# -gt 0 ]] && shift; cmd_init "$@" ;;
  start)                      [[ $# -gt 0 ]] && shift; cmd_start "$@" ;;
  stop)                       [[ $# -gt 0 ]] && shift; cmd_stop "$@" ;;
  attach)                     [[ $# -gt 0 ]] && shift; cmd_attach "$@" ;;
  status)                     [[ $# -gt 0 ]] && shift; cmd_status "$@" ;;
  doctor)                     [[ $# -gt 0 ]] && shift; cmd_doctor "$@" ;;
  version|--version|-v|-V)    cmd_version ;;
  help|--help|-h)             cmd_help ;;
  *)                          error "Unknown command: $1. Run 'smux help' for usage." ;;
esac
