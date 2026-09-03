# shellcheck shell=bash
#
# Shared helpers for cc-kit and the three tools.
#
# Source it, do not run it:
#
#     ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
#     . "$ROOT/lib/common.sh"
#
# Every tool here runs out of the checkout, so ROOT is the clone and nothing is ever
# copied to ~/.local/bin or anywhere else. Moving the clone breaks the launchd agents,
# which is the price of having no re-install step after a git pull.

CCW_STATE_ROOT="${CCW_STATE_ROOT:-$HOME/.local/state/ccw}"
CCW_CONFIG_ROOT="${CCW_CONFIG_ROOT:-$HOME/.config/ccw}"
CCW_ASSUME_YES="${CCW_ASSUME_YES:-0}"

# Read by cc-kit and lib/launchd.sh after they source this file. shellcheck analyzes each
# file on its own and cannot follow that, so it reports this one as unused.
# shellcheck disable=SC2034
CCW_LABEL_PREFIX="io.github.dthinkr.ccw"

# ---------------------------------------------------------------- output ----

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _c_bold=$'\033[1m'; _c_dim=$'\033[2m'; _c_red=$'\033[31m'
  _c_yellow=$'\033[33m'; _c_off=$'\033[0m'
else
  _c_bold=''; _c_dim=''; _c_red=''; _c_yellow=''; _c_off=''
fi

say()  { printf '%s\n' "$*"; }
head1() { printf '%s%s%s\n' "$_c_bold" "$*" "$_c_off"; }
dim()  { printf '%s%s%s\n' "$_c_dim" "$*" "$_c_off"; }
warn() { printf '%swarning:%s %s\n' "$_c_yellow" "$_c_off" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$_c_red" "$_c_off" "$*" >&2; exit 1; }

# tilde PATH -- print PATH with $HOME collapsed to ~, for anything a person reads.
# tilde PATH -- shortens a path for display. The checkout root becomes <checkout> rather
# than a home-relative path, because docs/what-this-touches.md is generated and committed,
# and whoever generates it should not publish where they happen to keep their clone.
tilde() {
  local p="$1"
  if [ -n "${CCW_ROOT:-}" ]; then
    case "$p" in
      "$CCW_ROOT"/*) printf '<checkout>%s' "${p#"$CCW_ROOT"}"; return ;;
      "$CCW_ROOT") printf '<checkout>'; return ;;
    esac
  fi
  case "$p" in
    "$HOME"/*) printf '~%s' "${p#"$HOME"}" ;;
    *) printf '%s' "$p" ;;
  esac
}

# commafy NUMBER -- 3142592479 becomes 3,142,592,479. bash printf %'d does not group
# under the C locale, and launchd jobs run under the C locale.
commafy() {
  printf '%s' "$1" | sed -e :a -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta'
}

# ------------------------------------------------------------- platform ----

require_macos() {
  [ "$(uname -s)" = "Darwin" ] || die "macOS only. These tools use launchd, the VS Code
paths under ~/Library, and the mitmproxy CA layout. There is no Linux or Windows path
and there will not be one."
}

# collect_lines ARRAYNAME
#
# Read stdin into a bash array, one element per non-empty line:
#
#     collect_lines DIRS < <(claude_ext_dirs)
#
# macOS ships bash 3.2 at /bin/bash and mapfile arrived in bash 4, so mapfile is not
# available here. Everything in this repo has to run on the system bash: asking people to
# install a newer one to run a workaround is a worse deal than the workaround.
collect_lines() {
  local __name="$1" __line
  eval "$__name=()"
  while IFS= read -r __line; do
    [ -n "$__line" ] || continue
    eval "$__name+=(\"\$__line\")"
  done
  return 0
}

# --------------------------------------------------------------- binaries ----

# resolve_bin NAME [candidate...]
#
# Print an absolute path to NAME, or nothing. Candidates are tried in order first, then
# PATH. Everything in this repo that launchd runs must call interpreters by absolute
# path: launchd jobs get a PATH without /opt/homebrew/bin, so a bare `node` is
# command-not-found inside the agent while working perfectly by hand. See
# docs/launchd-notes.md for the run that taught us this.
resolve_bin() {
  local name="$1"; shift
  local cand
  for cand in "$@"; do
    [ -n "$cand" ] && [ -x "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  done
  cand="$(command -v "$name" 2>/dev/null)" || true
  if [ -n "$cand" ]; then
    case "$cand" in
      /*) printf '%s\n' "$cand"; return 0 ;;
    esac
  fi
  return 1
}

resolve_node() {
  resolve_bin node /opt/homebrew/bin/node /usr/local/bin/node
}

resolve_python3() {
  resolve_bin python3 /usr/bin/python3 /opt/homebrew/bin/python3
}

resolve_go() {
  resolve_bin go /opt/homebrew/bin/go /usr/local/go/bin/go /usr/local/bin/go
}

# --------------------------------------------------------------- storage ----

# state_dir TOOL -> ~/.local/state/ccw/TOOL, created.
# Not ~/.claude/, which belongs to Anthropic and gets rewritten by their installer.
state_dir() {
  local d="$CCW_STATE_ROOT/$1"
  mkdir -p "$d"
  printf '%s\n' "$d"
}

config_dir() {
  mkdir -p "$CCW_CONFIG_ROOT"
  printf '%s\n' "$CCW_CONFIG_ROOT"
}

# backup_file PATH [SUFFIX]
#
# Copy PATH to PATH.bak-YYYYmmdd-HHMMSS and print the backup path. With SUFFIX given,
# copy to PATH.SUFFIX instead and do nothing if that file already exists. The fixed-name
# form exists for the extension bundle only, where rollback and the version migration
# both have to read the same pristine copy back.
backup_file() {
  local src="$1" fixed="${2:-}"
  [ -f "$src" ] || die "cannot back up $src: not a file"
  if [ -n "$fixed" ]; then
    local dst="$src.$fixed"
    [ -f "$dst" ] || cp -p "$src" "$dst"
    printf '%s\n' "$dst"
    return 0
  fi
  local stamp dst
  stamp="$(date +%Y%m%d-%H%M%S)"
  dst="$src.bak-$stamp"
  cp -p "$src" "$dst"
  printf '%s\n' "$dst"
}

# write_and_verify DEST VERIFIER_CMD...
#
# Read the new contents from stdin, write them to a temp file next to DEST, run
# VERIFIER_CMD on the temp file, and only then move it into place. A failed verifier
# leaves DEST untouched. This is the refuse-rather-than-degrade rule in one function.
write_and_verify() {
  local dest="$1"; shift
  local tmp
  tmp="$(mktemp "${dest}.new.XXXXXX")" || die "cannot create a temp file next to $dest"
  cat > "$tmp"
  if ! "$@" "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$dest"
  return 0
}

# ----------------------------------------------------------- confirmation ----

# plan_reset / plan_add / plan_show / plan_confirm
#
# Nothing in this repo writes before it has printed what it is about to write. Build the
# list with plan_add, print it with plan_show, and gate the write on plan_confirm.
CCW_PLAN=()

plan_reset() { CCW_PLAN=(); }
plan_add()   { CCW_PLAN+=("$1"); }

plan_show() {
  head1 "This will change:"
  local line
  # bash 3.2 treats "${arr[@]}" of an empty array as unbound under set -u, so every
  # possibly-empty array in this repo is expanded through the ${arr[@]+...} form.
  for line in ${CCW_PLAN[@]+"${CCW_PLAN[@]}"}; do
    printf '  %s\n' "$line"
  done
  printf '\n'
}

# confirm QUESTION
#
# Returns 0 on yes. With --yes (CCW_ASSUME_YES=1) it returns 0 and says so. With no
# terminal on stdin it refuses rather than assuming, because the callers that use this
# are the ones that edit a file Anthropic ships.
confirm() {
  local question="$1"
  if [ "$CCW_ASSUME_YES" = "1" ]; then
    say "$question [assuming yes, --yes was given]"
    return 0
  fi
  if [ ! -t 0 ] && [ ! -r /dev/tty ]; then
    die "$question
No terminal to ask on. Rerun with --yes if you have read the plan above."
  fi
  local reply=""
  if [ -t 0 ]; then
    read -r -p "$question [y/N] " reply
  else
    printf '%s [y/N] ' "$question" > /dev/tty
    read -r reply < /dev/tty
  fi
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) say "Nothing was changed."; return 1 ;;
  esac
}

# ------------------------------------------------------------ VS Code ----

# vscode_user_dirs
#
# Print the VS Code user settings directories that exist, one per line. Stable and
# Insiders are separate installs with separate settings files, and a machine can have
# both.
vscode_user_dirs() {
  local d
  for d in "$HOME/Library/Application Support/Code/User" \
           "$HOME/Library/Application Support/Code - Insiders/User"; do
    [ -d "$d" ] && printf '%s\n' "$d"
  done
  return 0
}

# claude_ext_dirs
#
# Print every installed anthropic.claude-code extension directory, one per line, newest
# last. The directory name carries the version, so a lexicographic sort is close enough
# to a version sort for the versions this extension has shipped.
#
# Stable VS Code and Insiders both, because auto-compact already handles both and a repo
# where one tool sees your editor and another silently does not is worse than either
# choice on its own. Cursor and other forks are out of scope: they ship their own build of
# the extension and nobody here has tested against it.
claude_ext_dirs() {
  local root d found=0
  {
    for root in "$HOME/.vscode" "$HOME/.vscode-insiders"; do
      [ -d "$root/extensions" ] || continue
      for d in "$root"/extensions/anthropic.claude-code-*/; do
        [ -f "$d/extension.js" ] || continue
        found=1
        # Version first so the sort below orders across both editors rather than
        # listing all of stable and then all of Insiders. Sorting per directory left
        # an older Insiders build looking newer than current stable, and every caller
        # that takes the last line would have picked the wrong bundle.
        printf '%s\t%s\n' "$(basename "${d%/}" | sed 's/^anthropic\.claude-code-//')" "${d%/}"
      done
    done
  } | sort -V | cut -f2-
  [ "$found" = 1 ]
}

# ext_version DIR -> the version segment of the directory name.
ext_version() {
  local base
  base="$(basename "$1")"
  base="${base#anthropic.claude-code-}"
  printf '%s\n' "$base"
}
