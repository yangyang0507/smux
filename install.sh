#!/usr/bin/env bash
# smux — one-command tmux setup
set -euo pipefail

VERSION="2.4.0"
REPO="yangyang0507/smux"
BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
SMUX_DIR="$HOME/.smux"
BIN_DIR="$SMUX_DIR/bin"
COMPLETION_DIR="$SMUX_DIR/completions"
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

  # shellcheck disable=SC2016
  local path_line='export PATH="$HOME/.smux/bin:$PATH"'

  # Write to rc file if not already present
  if [[ -f "$rc_file" ]] && ! grep -qF '.smux/bin' "$rc_file"; then
    info "Adding ~/.smux/bin to PATH in $rc_file"
    {
      echo ""
      echo "# smux"
      echo "$path_line"
    } >> "$rc_file"
  fi

  # Export into current shell if not already in PATH
  if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    export PATH="$BIN_DIR:$PATH"
  fi
}

rc_files() {
  printf '%s\n' \
    "$HOME/.bashrc" \
    "$HOME/.bash_profile" \
    "$HOME/.profile" \
    "$HOME/.zshrc"
}

rc_references_completion() {
  local name="$1" file rc
  file="$COMPLETION_DIR/${name}.bash"
  while IFS= read -r rc; do
    [[ -f "$rc" ]] || continue
    # shellcheck disable=SC2088
    if grep -Fq "$file" "$rc" ||
       grep -Fq "\$HOME/.smux/completions/${name}.bash" "$rc" ||
       grep -Fq "$HOME/.smux/completions/${name}.bash" "$rc" ||
       grep -Fq "~/.smux/completions/${name}.bash" "$rc" ||
       grep -Fq "$COMPLETION_DIR" "$rc" ||
       grep -Fq "\$HOME/.smux/completions" "$rc" ||
       grep -Fq "$HOME/.smux/completions" "$rc" ||
       grep -Fq "~/.smux/completions" "$rc"; then
      printf '%s\n' "$rc"
      return 0
    fi
  done < <(rc_files)
  return 1
}

completion_source_hint() {
  cat <<'EOF'
source "$HOME/.smux/completions/tmux-bridge.bash"
source "$HOME/.smux/completions/smux.bash"
EOF
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

checksum_file() {
  local file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{ print $1 }'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{ print $1 }'
  else
    error "Neither shasum nor sha256sum found. Install one and re-run."
  fi
}

validate_installed_file() {
  local file="$1" dest="${2:-$1}"
  case "$dest" in
    "$BIN_DIR/tmux-bridge"|"$BIN_DIR/smux") bash -n "$file" ;;
    *.bash|*.sh) bash -n "$file" ;;
    *) return 0 ;;
  esac
}

install_file_atomic() {
  local url="$1" dest="$2" mode="${3:-644}" tmp
  mkdir -p "$(dirname "$dest")"
  tmp="${dest}.new.$$"
  download "$url" "$tmp"
  chmod "$mode" "$tmp"
  if ! validate_installed_file "$tmp" "$dest"; then
    rm -f "$tmp"
    error "Validation failed for $dest"
  fi
  mv "$tmp" "$dest"
}

sync_manifest() {
  cat <<EOF
.tmux.conf|$SMUX_DIR/tmux.conf|644
scripts/tmux-bridge|$BIN_DIR/tmux-bridge|755
install.sh|$BIN_DIR/smux|755
completions/tmux-bridge.bash|$COMPLETION_DIR/tmux-bridge.bash|644
completions/smux.bash|$COMPLETION_DIR/smux.bash|644
EOF
}

source_for_rel() {
  local rel="$1" tmp_dir="$2" src
  src="$PWD/$rel"
  if [[ -f "$src" ]]; then
    printf '%s\n' "$src"
  else
    src="$tmp_dir/${rel//\//__}"
    download "$BASE_URL/$rel" "$src"
    printf '%s\n' "$src"
  fi
}

cmd_update_check() {
  local tmp_dir rel dest mode src src_sum dest_sum differences=0 missing=0
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/smux-update-check.XXXXXX")

  echo "smux update --check"
  while IFS='|' read -r rel dest mode; do
    [[ -n "$rel" ]] || continue
    src=$(source_for_rel "$rel" "$tmp_dir")
    src_sum=$(checksum_file "$src")
    if [[ ! -f "$dest" ]]; then
      printf "[missing] %-42s -> %s\n" "$rel" "$dest"
      ((++missing))
      continue
    fi
    dest_sum=$(checksum_file "$dest")
    if [[ "$src_sum" == "$dest_sum" ]]; then
      printf "[ok]      %-42s -> %s\n" "$rel" "$dest"
    else
      printf "[diff]    %-42s -> %s\n" "$rel" "$dest"
      ((++differences))
    fi
  done < <(sync_manifest)

  if (( differences == 0 && missing == 0 )); then
    doctor_ok "installed files match source"
    rm -rf "$tmp_dir"
    return 0
  fi
  doctor_warn "$differences differing, $missing missing. Run: smux update"
  rm -rf "$tmp_dir"
  return 1
}

install_manifest_files() {
  local dry_run="${1:-0}" rel dest mode
  while IFS='|' read -r rel dest mode; do
    [[ -n "$rel" ]] || continue
    if [[ "$dry_run" == "1" ]]; then
      printf "[dry-run] install %-42s -> %s\n" "$rel" "$dest"
    else
      info "Installing $rel..."
      install_file_atomic "$BASE_URL/$rel" "$dest" "$mode"
    fi
  done < <(sync_manifest)
}

# ================================================================
# smux v2 — declarative pane layout and lifecycle management
# ================================================================

# --- Text utilities ---

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

repeat_char() {
  local ch="$1" n="$2"
  if (( n <= 0 )); then return 0; fi
  local spaces
  printf -v spaces '%*s' "$n" ''
  printf '%s' "${spaces// /$ch}"
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
    clean=$(strip_inline_comment "$line")
    [[ -n "$clean" ]] || continue
    # Skip pipeline section and its indented steps
    clean=$(trim "$clean")
    [[ -n "$clean" ]] || continue
    [[ "$clean" =~ ^(pipeline:|steps:) ]] && continue
    [[ "${line:0:1}" == " " || "${line:0:1}" == $'\t' ]] && continue
    (( count += 1 ))
    [[ $count -eq 1 ]] || error ".smux has multiple layout lines. .smux requires exactly one layout line."
    found="$clean"
  done < "$file"
  [[ -n "$found" ]] || error ".smux is empty. .smux requires exactly one layout line. Run 'smux init' for examples."
  echo "$found"
}

strip_inline_comment() {
  local s="$1" inq=0 esc=0 buf="" ch i
  for (( i=0; i<${#s}; i++ )); do
    ch="${s:i:1}"
    if (( esc )); then
      buf="${buf}${ch}"
      esc=0
      continue
    fi
    if [[ "$ch" == "\\" && $inq -eq 1 ]]; then
      buf="${buf}${ch}"
      esc=1
      continue
    fi
    if [[ "$ch" == '"' ]]; then
      (( inq = 1 - inq ))
      buf="${buf}${ch}"
      continue
    fi
    if [[ "$ch" == "#" && $inq -eq 0 ]]; then
      break
    fi
    buf="${buf}${ch}"
  done
  printf '%s' "$buf"
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

# --- Pipeline parsing ---
SMUX_FLOW_STEP_FROM=()
SMUX_FLOW_STEP_TO=()
SMUX_FLOW_STEP_PROMPT=()
SMUX_FLOW_STEP_COUNT=0
SMUX_FLOW_NAME=""

pipeline_lines() {
  local file="$1" line clean
  while IFS= read -r line || [[ -n "$line" ]]; do
    clean=$(strip_inline_comment "$line")
    # Preserve indentation: check raw line, not trimmed
    if [[ "$line" =~ ^[[:space:]] ]]; then
      printf '%s\n' "$clean"
      continue
    fi
    clean=$(trim "$clean")
    [[ -n "$clean" ]] || continue
    [[ "$clean" =~ ^pipeline:|^steps: ]] && printf '%s\n' "$clean"
  done < "$file"
}

parse_pipeline() {
  local file="$1" line clean name="" in_steps=0
  SMUX_FLOW_NAME=""; SMUX_FLOW_STEP_FROM=(); SMUX_FLOW_STEP_TO=(); SMUX_FLOW_STEP_PROMPT=(); SMUX_FLOW_STEP_COUNT=0
  while IFS= read -r line; do
    clean=$(strip_inline_comment "$line")
    clean=$(trim "$clean")
    [[ -n "$clean" ]] || continue
    if [[ "$clean" =~ ^pipeline:[[:space:]]+ ]]; then
      name="${clean#pipeline:}"
      name="${name#"${name%%[![:space:]]*}"}"
      name="${name%"${name##*[![:space:]]}"}"
      # Strip surrounding double quotes (matches legacy xargs behavior)
      if [[ "${name:0:1}" == '"' && "${name: -1}" == '"' ]]; then
        name="${name:1:${#name}-2}"
      fi
      [[ -n "$name" ]] || error "Pipeline name is empty in $file"
      [[ -z "$SMUX_FLOW_NAME" ]] || error "Multiple pipeline: declarations in $file"
      SMUX_FLOW_NAME="$name"
    elif [[ "$clean" =~ ^steps: ]]; then
      in_steps=1
    elif [[ $in_steps -eq 1 ]]; then
      clean=$(trim "$clean")
      local from_label to_label prompt remainder
      from_label="${clean%%[[:space:]-]*}"
      from_label=$(trim "$from_label")
      remainder="${clean#*->}"
      remainder=$(trim "$remainder")
      to_label="${remainder%%[[:space:]]*}"
      remainder="${remainder#"$to_label"}"
      remainder=$(trim "$remainder")
      if [[ "${remainder:0:1}" == '"' ]]; then
        prompt="${remainder:1}"
        prompt="${prompt%\"}"
      else
        prompt="$remainder"
      fi
      [[ -n "$from_label" ]] || error "Missing 'from' label in pipeline step: $clean"
      [[ -n "$to_label" ]] || error "Missing 'to' label in pipeline step: $clean"
      local idx=$SMUX_FLOW_STEP_COUNT
      SMUX_FLOW_STEP_COUNT=$((SMUX_FLOW_STEP_COUNT + 1))
      SMUX_FLOW_STEP_FROM[idx]="$from_label"
      SMUX_FLOW_STEP_TO[idx]="$to_label"
      SMUX_FLOW_STEP_PROMPT[idx]="$prompt"
    fi
  done < <(pipeline_lines "$file")
  if [[ -z "$SMUX_FLOW_NAME" && $SMUX_FLOW_STEP_COUNT -gt 0 ]]; then
    error "Steps found without a 'pipeline:' name in $file"
  fi
  [[ $SMUX_FLOW_STEP_COUNT -gt 0 ]] || return 2
}

flow_state_file() {
  local session="$1" name="$2"
  echo "${TMPDIR:-/tmp}/tmux-bridge-flow-${session}-${name}"
}

flow_context_file() {
  local session="$1" name="$2"
  echo "${TMPDIR:-/tmp}/tmux-bridge-flow-${session}-${name}.ctx"
}

flow_label_for_pane() {
  local pane="$1"
  tmux display-message -t "$pane" -p '#{@name}' 2>/dev/null || echo "$pane"
}

find_pane_by_label() {
  local label="$1"
  local pane
  pane=$(tmux list-panes -a -F '#{pane_id} #{@name}' 2>/dev/null | grep " ${label}$" | head -1 | awk '{print $1}')
  [[ -n "$pane" ]] || error "No pane found with label '$label'. Verify the pipeline labels match agent pane labels. Run 'smux status --agents' to see all labeled panes."
  echo "$pane"
}

# Portable base64 encode via system base64 command (present on macOS and Linux).
b64_encode() { printf '%s' "$1" | base64 | tr -d '\n'; }

# Emit TSV+base64 pipeline output after parse_pipeline has populated SMUX_FLOW_* vars.
# Format matches tests/test_dsl_spec.sh golden output.
emit_pipeline_tsv() {
  printf 'pipeline\t%s\tsteps=%d\n' "$(b64_encode "$SMUX_FLOW_NAME")" "$SMUX_FLOW_STEP_COUNT"
  local j
  for (( j=0; j<SMUX_FLOW_STEP_COUNT; j++ )); do
    printf 'step\t%d\t%s\t%s\t%s\n' "$j" \
      "${SMUX_FLOW_STEP_FROM[j]}" \
      "${SMUX_FLOW_STEP_TO[j]}" \
      "$(b64_encode "${SMUX_FLOW_STEP_PROMPT[j]}")"
  done
}

# --- Parser state: populated by parse_layout(), consumed by start_layout() and preview ---
# Arrays are indexed by global pane index (0..SMUX_PANE_COUNT-1).
# SMUX_COL_START[c] = first pane index in column c; SMUX_COL_COUNT[c] = number of panes in column c.
SMUX_PANE_LABELS=()
SMUX_PANE_COMMANDS=()
# shellcheck disable=SC2034
SMUX_PANE_COLS=()
SMUX_COL_START=()
SMUX_COL_COUNT=()
COL_WIDTH=()
SMUX_PANE_COUNT=0
SMUX_COL_COUNT_TOTAL=0

# Parse a .smux layout line into the global pane/column arrays.
# Splits by '|' to get columns, then by ',' to get panes within each column.
# Each cell: LABEL [COMMAND].  Label is the first [A-Za-z0-9_.-]+ word;
# everything after is the command (may be empty = shell pane).
parse_layout() {
  local line="$1" col cell label cmd rest col_start col_count
  quote_balanced "$line" || error "Unclosed quote in .smux layout: $line. Fix the quote, then run 'smux start --dry-run' to verify."
  SMUX_PANE_LABELS=(); SMUX_PANE_COMMANDS=(); SMUX_PANE_COLS=(); SMUX_COL_START=(); SMUX_COL_COUNT=()
  SMUX_PANE_COUNT=0; SMUX_COL_COUNT_TOTAL=0
  while IFS= read -r col; do
    col=$(trim "$col")
    [[ -n "$col" ]] || error "Empty column in .smux layout: $line. Remove the extra '|' or add a label."
    col_start=$SMUX_PANE_COUNT
    col_count=0
    while IFS= read -r cell; do
      cell=$(trim "$cell")
      [[ -n "$cell" ]] || error "Empty pane in .smux layout: $line. Remove the extra comma or add a label."
      label="${cell%%[[:space:]]*}"
      rest="${cell#"$label"}"
      cmd=$(unquote_command "$rest")
      valid_name "$label" || error "Invalid label '$label'. Labels must match [A-Za-z0-9_.-]+. Use a label like 'test-runner npm test'."
      SMUX_PANE_LABELS[SMUX_PANE_COUNT]="$label"
      SMUX_PANE_COMMANDS[SMUX_PANE_COUNT]="$cmd"
      # shellcheck disable=SC2034
      SMUX_PANE_COLS[SMUX_PANE_COUNT]="$SMUX_COL_COUNT_TOTAL"
      (( SMUX_PANE_COUNT += 1, col_count += 1 ))
    done < <(split_aware "$col" ",")
    SMUX_COL_START[SMUX_COL_COUNT_TOTAL]="$col_start"
    SMUX_COL_COUNT[SMUX_COL_COUNT_TOTAL]="$col_count"
    (( SMUX_COL_COUNT_TOTAL += 1 ))
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
  for (( i=0; i<SMUX_PANE_COUNT; i++ )); do
    ((${#SMUX_PANE_LABELS[$i]} > labelw)) && labelw=${#SMUX_PANE_LABELS[$i]}
  done
  echo "session: $session"
  echo "project: $project"
  echo "panes:"
  for (( i=0; i<SMUX_PANE_COUNT; i++ )); do
    d=$(display_cmd "${SMUX_PANE_COMMANDS[$i]}")
    printf "  %-*s  %s\n" "$labelw" "${SMUX_PANE_LABELS[$i]}" "$d"
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
  n="${SMUX_COL_COUNT[$col]}"; start="${SMUX_COL_START[$col]}"
  if (( n == 1 )); then
    mid=$((height/2))
    (( row == mid-1 )) && text="${SMUX_PANE_LABELS[$start]}"
    (( row == mid )) && text=$(display_cmd "${SMUX_PANE_COMMANDS[$start]}")
  else
    for (( p=0; p<n; p++ )); do
      off=$((p*3)); idx=$((start+p))
      (( row == off )) && text="${SMUX_PANE_LABELS[$idx]}"
      (( row == off+1 )) && text=$(display_cmd "${SMUX_PANE_COMMANDS[$idx]}")
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
  for (( c=0; c<SMUX_COL_COUNT_TOTAL; c++ )); do
    width=10
    for (( i=0; i<SMUX_COL_COUNT[c]; i++ )); do
      local idx=$((SMUX_COL_START[c]+i)) d
      d=$(display_cmd "${SMUX_PANE_COMMANDS[$idx]}")
      ((${#SMUX_PANE_LABELS[$idx]}+2 > width)) && width=$((${#SMUX_PANE_LABELS[$idx]}+2))
      ((${#d}+2 > width)) && width=$((${#d}+2))
    done
    (( width > 24 )) && width=24
    COL_WIDTH[c]="$width"
    local rows=$((SMUX_COL_COUNT[c]*2 + SMUX_COL_COUNT[c] - 1))
    (( rows > max_rows )) && max_rows=$rows
  done
  # --- Draw top border: ┌──┬──┬──┐ ---
  printf '┌'
  for (( c=0; c<SMUX_COL_COUNT_TOTAL; c++ )); do
    repeat_char "─" "${COL_WIDTH[$c]}"
    (( c == SMUX_COL_COUNT_TOTAL-1 )) && printf '┐' || printf '┬'
  done
  printf '\n'
  # --- Draw rows ---
  for (( row=0; row<max_rows; row++ )); do
    printf '│'
    for (( c=0; c<SMUX_COL_COUNT_TOTAL; c++ )); do
      preview_line_for "$c" "$row" "$max_rows" "${COL_WIDTH[$c]}"
      printf '│'
    done
    printf '\n'
  done
  # --- Draw bottom border: └──┴──┴──┘ ---
  printf '└'
  for (( c=0; c<SMUX_COL_COUNT_TOTAL; c++ )); do
    repeat_char "─" "${COL_WIDTH[$c]}"
    (( c == SMUX_COL_COUNT_TOTAL-1 )) && printf '┘' || printf '┴'
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
  for (( col=1; col<SMUX_COL_COUNT_TOTAL; col++ )); do
    prev="${COL_TOP[$((col-1))]}"                              # target = previous column's top pane
    pane=$(tmux split-window -h -t "$prev" -c "$project" -P -F '#{pane_id}')
    idx="${SMUX_COL_START[col]}"
    PANE_IDS[idx]="$pane"
    COL_TOP[col]="$pane"
  done
  tmux select-layout -t "$session:0" even-horizontal >/dev/null 2>&1 || true
  # --- Phase 2: stack panes vertically within each column ---
  for (( col=0; col<SMUX_COL_COUNT_TOTAL; col++ )); do
    k="${SMUX_COL_COUNT[col]}"
    prev="${COL_TOP[col]}"
    for (( j=1; j<k; j++ )); do
      pct=$((100*(k-j)/(k-j+1)))                                # split remaining space proportionally
      (( pct < 1 )) && pct=50
      pane=$(tmux split-window -v -p "$pct" -t "$prev" -c "$project" -P -F '#{pane_id}')
      idx=$((SMUX_COL_START[col]+j))
      PANE_IDS[idx]="$pane"
      prev="$pane"
    done
  done
  # --- Phase 3: label and launch ---
  for (( idx=0; idx<SMUX_PANE_COUNT; idx++ )); do
    pane="${PANE_IDS[$idx]}"
    if [[ -n "${SMUX_PANE_LABELS[$idx]}" ]]; then
      tmux set-option -p -t "$pane" @smux_label "${SMUX_PANE_LABELS[$idx]}" >/dev/null
      tmux set-option -p -t "$pane" @name "${SMUX_PANE_LABELS[$idx]}" >/dev/null
    fi
    send_command_to_pane "$pane" "${SMUX_PANE_COMMANDS[$idx]}"
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
  mkdir -p "$SMUX_DIR" "$BIN_DIR" "$COMPLETION_DIR" "$BACKUP_DIR"

  # 4. Back up existing config
  backup_existing

  # 5. Install managed files atomically
  install_manifest_files 0

  # 6. Symlink tmux config
  mkdir -p "$TMUX_XDG_DIR"
  ln -sf "$SMUX_DIR/tmux.conf" "$TMUX_XDG_DIR/tmux.conf"

  # 7. Ensure PATH
  ensure_path

  # 8. Reload tmux if running
  if tmux list-sessions &>/dev/null; then
    tmux source-file "$SMUX_DIR/tmux.conf" 2>/dev/null && info "Reloaded tmux config." || true
  fi

  # 9. Done
  echo ""
  printf '%s%s%s\n' "${GREEN}${BOLD}" "smux installed!" "${NC}"
  echo ""
  echo "  Config:       ~/.smux/tmux.conf"
  echo "  tmux-bridge:  ~/.smux/bin/tmux-bridge"
  echo "  smux CLI:     ~/.smux/bin/smux"
  echo "  Completions:  ~/.smux/completions/"
  echo ""
  echo "  Run 'smux help' for commands."
  if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    echo ""
    warn "Restart your shell or run: export PATH=\"\$HOME/.smux/bin:\$PATH\""
  fi
  echo ""
  echo "  To enable tab completion, add to your shell rc:"
  completion_source_hint | sed 's/^/    /'
  echo ""
  echo "  To install smux as an agent skill:"
  echo "    npx skills add yangyang0507/smux"
}

cmd_update() {
  local check=0 dry_run=0
  while (($#)); do
    case "$1" in
      --check) check=1; shift ;;
      --dry-run) dry_run=1; shift ;;
      --help|-h)
        cat <<'EOF'
Usage: smux update [--check] [--dry-run]

  --check    Compare source files with installed copies and report drift
  --dry-run  Show files that would be installed, without writing anything
EOF
        return 0 ;;
      *) error "Unknown update option: $1" ;;
    esac
  done

  if (( check )); then
    cmd_update_check
    return $?
  fi

  info "Updating smux..."

  if (( dry_run )); then
    install_manifest_files 1
    info "Dry run complete. No files were changed."
    return 0
  fi

  mkdir -p "$SMUX_DIR" "$BIN_DIR" "$COMPLETION_DIR" "$BACKUP_DIR"
  backup_existing

  install_manifest_files 0

  if tmux list-sessions &>/dev/null; then
    tmux source-file "$SMUX_DIR/tmux.conf" 2>/dev/null && info "Reloaded tmux config." || true
  fi

  echo ""
  info "To update the smux agent skill: npx skills add yangyang0507/smux"

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
  latest_backup=$(find "$BACKUP_DIR" -maxdepth 1 -name 'tmux.conf.*' -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1 || true)
  if [[ -n "$latest_backup" ]]; then
    info "Restoring backup: $latest_backup"
    mkdir -p "$TMUX_XDG_DIR"
    cp "$latest_backup" "$TMUX_XDG_DIR/tmux.conf"
  fi

  # Remove smux directory
  rm -rf "$SMUX_DIR"
  info "Removed ~/.smux/"

  echo ""
  printf '%s%s%s\n' "${GREEN}${BOLD}" "smux uninstalled." "${NC}"
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
  local agents=0
  while (($#)); do
    case "$1" in
      --agents) agents=1; shift ;;
      --help|-h)
        cat <<'EOF'
Usage: smux status [--agents]

  --agents  List agent panes with labels, pane IDs, commands, and working dirs
EOF
        return 0 ;;
      *) error "Unknown status option: $1" ;;
    esac
  done
  command -v tmux >/dev/null 2>&1 || error "tmux not found."
  if (( agents )); then
    printf "%-12s %-8s %-16s %-22s %s\n" "SESSION" "PANE" "LABEL" "COMMAND" "CWD"
    { tmux list-sessions -F '#{session_name}|#{@smux_project}' 2>/dev/null || true; } |
    while IFS='|' read -r session project; do
      [[ -n "$project" ]] || continue
      tmux list-panes -t "$session" \
        -F '#{session_name}|#{pane_id}|#{@name}|#{pane_current_command}|#{pane_current_path}' 2>/dev/null |
      while IFS='|' read -r sess pane label command cwd; do
        [[ -n "$label" ]] || continue
        cwd="${cwd/#$HOME/~}"
        printf "%-12s %-8s %-16s %-22s %s\n" "$sess" "$pane" "$label" "$command" "$cwd"
      done
    done
    return 0
  fi

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
  #                full-line or inline comment outside double quotes

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

cmd_parse_pipeline() {
  local file="${1:-}"
  [[ -n "$file" ]] || error "Usage: smux parse-pipeline <file>"
  [[ -f "$file" ]] || error "File not found: $file"
  parse_pipeline "$file"
  emit_pipeline_tsv
}

cmd_flow() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    start)  cmd_flow_start "$@" ;;
    status) cmd_flow_status "$@" ;;
    reset)  cmd_flow_reset "$@" ;;
    -h|--help)
      cat <<'EOF'
Usage: smux flow <command>

Commands:
  start   [--pipeline <name>] [message...]  Start a pipeline with an initial task
  status                                    Show active pipeline progress
  reset   [--pipeline <name>]               Reset pipeline to the first step
  reset   --stale [minutes]                  Clean up stale flow files (default: 24h)

Examples:
  smux flow start "Implement login function"
  smux flow start --pipeline review-flow "Review src/auth.ts"
  smux flow status
  smux flow reset
EOF
      ;;
    *) error "Unknown flow command: $sub. Use 'smux flow' to see options." ;;
  esac
}

cmd_flow_start() {
  local pipeline_name="" emsg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pipeline)
        [[ $# -ge 2 ]] || error "--pipeline requires a value"
        pipeline_name="$2"; shift 2 ;;
      --)
        shift; emsg="$*"; break ;;
      -*)
        error "Unknown flow start option: $1" ;;
      *)
        emsg="$*"; break ;;
    esac
  done

  command -v tmux >/dev/null 2>&1 || error "tmux not found."
  local project session
  project=$(find_project_root)
  session=$(session_name_for "$project")
  tmux has-session -t "$session" 2>/dev/null || error "No smux session found. Run 'smux start' first."

  parse_pipeline "$project/.smux" || error "No pipeline defined in $project/.smux. Add a 'pipeline:' block."

  if [[ -n "$pipeline_name" ]]; then
    [[ "$pipeline_name" == "$SMUX_FLOW_NAME" ]] || error "Pipeline '$pipeline_name' not found. Available: $SMUX_FLOW_NAME"
  fi

  local state_file
  state_file=$(flow_state_file "$session" "$SMUX_FLOW_NAME")
  if [[ -f "$state_file" ]]; then
    local existing_step
    existing_step=$(cat "$state_file")
    error "Pipeline '$SMUX_FLOW_NAME' is already running at step $((existing_step + 1))/$SMUX_FLOW_STEP_COUNT. Run 'smux flow reset' to restart."
  fi

  local first_label="${SMUX_FLOW_STEP_FROM[0]}"
  local first_pane
  first_pane=$(find_pane_by_label "$first_label")

  local prompt="${SMUX_FLOW_STEP_PROMPT[0]}"
  [[ -n "$emsg" ]] && prompt="$emsg"

  echo "[flow] Starting '$SMUX_FLOW_NAME' ($SMUX_FLOW_STEP_COUNT steps)"
  echo "[flow] Step 1/$SMUX_FLOW_STEP_COUNT → $first_label: $prompt"

  echo "0" > "$state_file"

  local ctx_file session_label pane_label
  ctx_file=$(flow_context_file "$session" "$SMUX_FLOW_NAME")
  session_label=$(tmux display-message -t "$session" -p '#{session_name}' 2>/dev/null || echo "$session")
  {
    echo "session=$session_label"
    echo "name=$SMUX_FLOW_NAME"
    echo "steps=$SMUX_FLOW_STEP_COUNT"
    local i
    for (( i=0; i<SMUX_FLOW_STEP_COUNT; i++ )); do
      pane_label=$(find_pane_by_label "${SMUX_FLOW_STEP_TO[$i]}")
      echo "step_${i}=${SMUX_FLOW_STEP_FROM[$i]}|${SMUX_FLOW_STEP_TO[$i]}|${pane_label}|${SMUX_FLOW_STEP_PROMPT[$i]}"
    done
  } > "$ctx_file"

  local header="[flow: ${SMUX_FLOW_NAME} step 1/${SMUX_FLOW_STEP_COUNT}]"
  tmux send-keys -t "$first_pane" -l -- "$header $prompt"
  tmux send-keys -t "$first_pane" Enter
}

cmd_flow_status() {
  local project session state_file step_idx
  project=$(find_project_root 2>/dev/null) || error "No project found. Run 'smux flow status' from a project directory."
  session=$(session_name_for "$project")

  parse_pipeline "$project/.smux" || error "No pipeline defined."

  state_file=$(flow_state_file "$session" "$SMUX_FLOW_NAME")
  if [[ ! -f "$state_file" ]]; then
    echo "No active pipeline for session '$session'."
    return 1
  fi

  step_idx=$(cat "$state_file")
  echo "Pipeline: $SMUX_FLOW_NAME"
  local i label status
  for (( i=0; i<SMUX_FLOW_STEP_COUNT; i++ )); do
    label="${SMUX_FLOW_STEP_FROM[$i]} → ${SMUX_FLOW_STEP_TO[$i]}"
    if (( i < step_idx )); then
      status="✓ done"
    elif (( i == step_idx )); then
      status="● active"
    else
      status="○ pending"
    fi
    echo "  step $((i+1))/$SMUX_FLOW_STEP_COUNT $label — $status"
  done
}

cmd_flow_reset() {
  # --stale: clean up flow files older than N minutes (default 24h)
  if [[ "${1:-}" == "--stale" ]]; then
    shift
    local older_than="1440"
    if [[ $# -ge 1 ]]; then
      local arg="$1"
      [[ "$arg" =~ ^[0-9]+$ && "$arg" -gt 0 ]] || error "--stale minutes must be a positive integer, got: $arg"
      older_than="$arg"
      shift
    fi
    [[ $# -eq 0 ]] || error "Usage: smux flow reset --stale [minutes]"
    local stale
    stale=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name "tmux-bridge-flow-*-*" \
      -mmin +"$older_than" 2>/dev/null || true)
    if [[ -z "$stale" ]]; then
      echo "No stale flow files found."
      return 0
    fi
    local count=0 f
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      rm -f "$f"
      rm -f "${f%.ctx}"
      (( ++count ))
    done <<< "$stale"
    echo "Removed $count stale flow file(s) (older than $older_than minutes)."
    return 0
  fi

  local pipeline_name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pipeline)
        [[ $# -ge 2 ]] || error "--pipeline requires a value"
        pipeline_name="$2"; shift 2 ;;
      *)
        error "Unknown flow reset option: $1" ;;
    esac
  done

  local project session state_file
  project=$(find_project_root 2>/dev/null) || error "No project found."
  session=$(session_name_for "$project")

  parse_pipeline "$project/.smux" || error "No pipeline defined."

  [[ -z "$pipeline_name" || "$pipeline_name" == "$SMUX_FLOW_NAME" ]] || error "Pipeline '$pipeline_name' not found."

  state_file=$(flow_state_file "$session" "$SMUX_FLOW_NAME")
  rm -f "$state_file"
  rm -f "$(flow_context_file "$session" "$SMUX_FLOW_NAME")"
  echo "Pipeline '$SMUX_FLOW_NAME' reset."
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

  local bridge_completion smux_completion completion_rc
  bridge_completion="$COMPLETION_DIR/tmux-bridge.bash"
  smux_completion="$COMPLETION_DIR/smux.bash"
  if [[ -f "$bridge_completion" && -f "$smux_completion" ]]; then
    doctor_ok "shell completions installed: $COMPLETION_DIR"
    if completion_rc=$(rc_references_completion "tmux-bridge") &&
       rc_references_completion "smux" >/dev/null; then
      doctor_ok "shell completions sourced: $completion_rc"
    else
      doctor_warn "shell completions not sourced. Add these lines to ~/.bashrc, ~/.bash_profile, or ~/.zshrc:"
      completion_source_hint | while IFS= read -r line; do
        doctor_info "  $line"
      done
    fi
  else
    doctor_warn "shell completions not installed. Fix: smux update"
  fi

  local sync_report
  sync_report=$(mktemp "${TMPDIR:-/tmp}/smux-doctor-sync.XXXXXX")
  if cmd_update_check >"$sync_report" 2>&1; then
    doctor_ok "installed files match source"
  else
    doctor_warn "installed files differ from source. Run: smux update --check"
    while IFS= read -r line; do
      case "$line" in
        \[diff\]*|\[missing\]*) doctor_info "$line" ;;
      esac
    done <"$sync_report"
  fi
  rm -f "$sync_report"

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
       parse_err=$( (parse_layout "$line"; printf '%s|%s' "$SMUX_PANE_COUNT" "$SMUX_COL_COUNT_TOTAL") 2>"$project_err"); then
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

  if command -v tmux >/dev/null 2>&1 && tmux list-sessions >/dev/null 2>&1; then
    local mode_found=0 mode_sess mode_project mode_pane mode_label mode_state
    while IFS='|' read -r mode_sess mode_project; do
      [[ -n "$mode_project" ]] || continue
      while IFS='|' read -r mode_pane mode_label mode_state; do
        [[ "$mode_state" == "1" ]] || continue
        mode_found=1
        doctor_warn "pane ${mode_label:-$mode_pane} ($mode_pane) is in tmux mode/prompt. Run: tmux-bridge wake $mode_pane"
      done < <(tmux list-panes -t "$mode_sess" -F '#{pane_id}|#{@name}|#{pane_in_mode}' 2>/dev/null)
    done < <(tmux list-sessions -F '#{session_name}|#{@smux_project}' 2>/dev/null)
    (( mode_found )) || doctor_ok "smux panes are in normal input mode"
  fi

  local stale_ctx
  stale_ctx=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name "tmux-bridge-flow-*-*.ctx" \
    -mmin +1440 2>/dev/null | head -10 || true)
  if [[ -n "$stale_ctx" ]]; then
    doctor_warn "Stale flow files found (older than 24h):"
    local sf
    while IFS= read -r sf; do
      [[ -n "$sf" ]] && doctor_info "  $sf"
    done <<< "$stale_ctx"
    doctor_info "Clean with: smux flow reset --stale"
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
  status      List smux-managed sessions or agent panes
  flow        Agent workflow pipeline (start/status/reset)
  doctor      Diagnose smux and tmux setup
  version     Print version
  help        Show this help

Workspace:
  smux init [--force] '<layout>'
  smux start [-n <name>] [-d] [--replace] [--dry-run] [--preview]
  smux stop  [-n <name>]
  smux attach [-n <name>]
  smux status [--agents]
  smux update [--check] [--dry-run]

Pipelines:
  smux flow start [--pipeline <name>] [message...]
  smux flow status
  smux flow reset [--pipeline <name>]

Files:
  ~/.smux/tmux.conf          tmux configuration
  ~/.smux/bin/tmux-bridge    cross-pane communication CLI
  ~/.smux/bin/smux           this CLI
  ~/.smux/completions/       shell completion scripts
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
  flow)                       [[ $# -gt 0 ]] && shift; cmd_flow "$@" ;;
  parse-pipeline)             [[ $# -gt 0 ]] && shift; cmd_parse_pipeline "$@" ;;
  doctor)                     [[ $# -gt 0 ]] && shift; cmd_doctor "$@" ;;
  version|--version|-v|-V)    cmd_version ;;
  help|--help|-h)             cmd_help ;;
  *)                          error "Unknown command: $1. Run 'smux help' for usage." ;;
esac
