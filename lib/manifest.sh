# shellcheck shell=bash
#
# Reads tools/<tool>/manifest.conf. One hand-written list of touched paths per tool, and
# everything else is generated from it: the uninstall path, the status report, and
# docs/what-this-touches.md.
#
# A hand-maintained list of modified files goes stale silently and takes the credibility
# of the rest of the page with it, so it is written once, next to the code that writes
# those files, and read from there.
#
# The file is shell key-value, sourced by bash. It is not TOML. tomllib landed in Python
# 3.11 and the /usr/bin/python3 stub on a stock macOS is older than that, so a TOML
# manifest would add a dependency to a repo whose whole point is not having any.
#
# Format:
#
#   TOOL_NAME="open-binary"
#   TOOL_TITLE="One line, what the tool does"
#   TOOL_AGENT_LABEL="io.github.dthinkr.ccw.open-binary"     # empty if no agent
#   TOOL_TOUCHES=(
#     "kind|path|note|undo command"
#   )
#
# kind is one of:
#   agent    a launchd plist. Generic uninstall boots the label out and removes it.
#   state    a directory under ~/.local/state/ccw. Generic uninstall removes it.
#   build    an artifact built inside the checkout. Generic uninstall removes it.
#   config   a file you wrote yourself. Never removed for you, only reported.
#   runtime  something a running process owns, such as a socket. Reported, never removed.
#   patch    a file belonging to someone else, edited in place. Tool-specific undo.
#   backup   a backup this repo created. Tool-specific undo.
#   setting  a key in a settings file. Tool-specific undo.

manifest_load() {
  local tool_dir="$1"
  local conf="$tool_dir/manifest.conf"
  [ -f "$conf" ] || die "no manifest at $conf"
  TOOL_NAME=""; TOOL_TITLE=""; TOOL_AGENT_LABEL=""; TOOL_TOUCHES=()
  # shellcheck disable=SC1090
  . "$conf"
  [ -n "$TOOL_NAME" ] || die "$conf does not set TOOL_NAME"
  [ "${#TOOL_TOUCHES[@]}" -gt 0 ] || die "$conf declares no TOOL_TOUCHES"
}

# manifest_each KIND -- prints "path<TAB>note<TAB>undo" for every entry of that kind.
# KIND "*" prints all of them.
manifest_each() {
  local want="$1" entry kind path note undo
  for entry in "${TOOL_TOUCHES[@]}"; do
    IFS='|' read -r kind path note undo <<< "$entry"
    if [ "$want" = "*" ] || [ "$kind" = "$want" ]; then
      printf '%s\t%s\t%s\t%s\n' "$kind" "$path" "$note" "$undo"
    fi
  done
}

# manifest_print_touched -- what an installer prints when it finishes.
manifest_print_touched() {
  local kind path note undo
  head1 "Touched:"
  while IFS=$'\t' read -r kind path note undo; do
    [ -n "$path" ] || continue
    if [ -e "$path" ]; then
      printf '  %s\n' "$(tilde "$path")"
    else
      printf '  %s %s\n' "$(tilde "$path")" "$(dim '(not present)')"
    fi
    if [ -n "$note" ]; then printf '      %s\n' "$note"; fi
  done < <(manifest_each '*')
  printf '\n'
}

# manifest_plan_add -- put every declared path into the plan an installer shows before
# it writes anything.
manifest_plan_add() {
  local kind path note undo
  while IFS=$'\t' read -r kind path note undo; do
    [ -n "$path" ] || continue
    plan_add "$(printf '%-8s %s' "$kind" "$(tilde "$path")")"
    if [ -n "$note" ]; then plan_add "$(printf '%-8s   %s' "" "$note")"; fi
  done < <(manifest_each '*')
  return 0
}

# manifest_generic_uninstall -- reverses the kinds that need no tool-specific knowledge.
# Tool uninstallers call this and then handle their own patch, backup and setting
# entries. Prints one line per action.
manifest_generic_uninstall() {
  local kind path note undo
  while IFS=$'\t' read -r kind path note undo; do
    case "$kind" in
      agent)
        if [ -n "$TOOL_AGENT_LABEL" ] && agent_loaded "$TOOL_AGENT_LABEL"; then
          agent_unload "$TOOL_AGENT_LABEL"
          say "  booted out $TOOL_AGENT_LABEL"
        fi
        if [ -f "$path" ]; then
          rm -f "$path"
          say "  removed $(tilde "$path")"
        fi
        ;;
      state)
        if [ -e "$path" ]; then
          rm -rf "$path"
          say "  removed $(tilde "$path")"
        fi
        ;;
      build)
        if [ -e "$path" ]; then
          rm -f "$path"
          say "  removed $(tilde "$path")"
        fi
        ;;
      config)
        if [ -e "$path" ]; then
          say "  left $(tilde "$path") alone. You wrote it, remove it yourself:"
          say "      rm -f $(tilde "$path")"
        fi
        ;;
      runtime)
        # Owned by a running process. Removing it under a live session would take the
        # side channel away from a session that is still using it.
        if [ -e "$path" ]; then
          say "  left $(tilde "$path") alone, a running process owns it"
        fi
        ;;
    esac
  done < <(manifest_each '*')
  return 0
}

# ---------------------------------------------------------------------------
# docs/what-this-touches.md generator.
#
#     bash lib/manifest.sh docs > docs/what-this-touches.md
#
# CI regenerates it and fails on a diff, so the page cannot drift away from the
# manifests without someone noticing.
# ---------------------------------------------------------------------------

manifest_docs() {
  local root="$1" tool conf
  cat <<'HEADER'
# What this touches on your machine

Generated from `tools/*/manifest.conf` by `lib/manifest.sh`. Do not edit this file by
hand. CI regenerates it and fails if the result differs from what is checked in.

If a path is not on this page, no tool in this repo writes it.

Two paths are shared by all three tools and are removed by hand:

```sh
rm -rf ~/.local/state/ccw ~/.config/ccw
```

HEADER

  for tool in open-binary auto-compact rc-proxy; do
    conf="$root/tools/$tool/manifest.conf"
    [ -f "$conf" ] || continue
    (
      manifest_load "$root/tools/$tool"
      printf '## `%s`\n\n%s\n\n' "$TOOL_NAME" "$TOOL_TITLE"
      printf '| path | what it is | undo |\n|---|---|---|\n'
      local kind path note undo
      while IFS=$'\t' read -r kind path note undo; do
        printf '| `%s` | %s | %s |\n' "$(tilde "$path")" "$note" "${undo:-see the tool README}"
      done < <(manifest_each '*')
      printf '\n'
    )
  done

  cat <<'FOOTER'
## Nothing else

No tool here copies itself to `~/.local/bin`, `~/.local/share` or `~/.claude/scripts`.
Every launchd plist points at a file inside this checkout by absolute path. That is why
`git pull` is the whole update procedure, and also why moving the checkout breaks the
agents.
FOOTER
}

# Runnable as well as sourceable, so CI can call it without a shell wrapper.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  _root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # shellcheck source=lib/common.sh
  . "$_root/lib/common.sh"
  # shellcheck source=lib/launchd.sh
  . "$_root/lib/launchd.sh"
  # The generated page has to be identical on every machine or CI would fail on the
  # diff, so paths inside the clone print as <checkout> rather than as this clone's
  # absolute path. $HOME collapses to ~ the same way, in tilde().
  CCW_ROOT="<checkout>"
  export CCW_ROOT
  case "${1:-}" in
    docs) manifest_docs "$_root" ;;
    *) die "usage: manifest.sh docs" ;;
  esac
fi
