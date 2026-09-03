# shellcheck shell=bash
#
# launchd helpers. Source after lib/common.sh.
#
# Only bootstrap, bootout and kickstart are used. The legacy load and unload appear
# nowhere in this repo. They still work on macOS 27 but report success for jobs they did
# not touch, which is how an installer ends up believing it replaced an agent that is
# still running the old program.

# emit_plist PATH
#
# Reads the job description from these variables and writes a plist to PATH. Runs
# plutil -lint on a temp copy first, so a malformed plist never lands on disk.
#
#   PLIST_LABEL      required
#   PLIST_PROGRAM    required, array, argv of the job
#   PLIST_WATCH      array of WatchPaths, optional
#   PLIST_INTERVAL   StartInterval in seconds, optional
#   PLIST_KEEPALIVE  1 for KeepAlive true, optional
#   PLIST_RUNATLOAD  1 for RunAtLoad true, optional
#   PLIST_STDOUT     StandardOutPath, optional
#   PLIST_STDERR     StandardErrorPath, optional
#   PLIST_PROCTYPE   ProcessType, optional
#   PLIST_NOFILE     SoftResourceLimits NumberOfFiles, optional
#   PLIST_ENV        array of KEY=VALUE strings, optional
emit_plist() {
  local dest="$1"
  # Optional arrays have to exist before set -u sees them.
  [ -n "${PLIST_PROGRAM+x}" ] || PLIST_PROGRAM=()
  [ -n "${PLIST_WATCH+x}" ] || PLIST_WATCH=()
  [ -n "${PLIST_ENV+x}" ] || PLIST_ENV=()
  [ -n "${PLIST_LABEL:-}" ] || die "emit_plist: PLIST_LABEL is unset"
  [ "${#PLIST_PROGRAM[@]}" -gt 0 ] || die "emit_plist: PLIST_PROGRAM is empty"

  mkdir -p "$(dirname "$dest")"
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0">'
    printf '%s\n' '<dict>'
    printf '  <key>Label</key>\n  <string>%s</string>\n' "$(xml_escape "$PLIST_LABEL")"

    printf '  <key>ProgramArguments</key>\n  <array>\n'
    local arg
    for arg in "${PLIST_PROGRAM[@]}"; do
      printf '    <string>%s</string>\n' "$(xml_escape "$arg")"
    done
    printf '  </array>\n'

    if [ "${#PLIST_WATCH[@]}" -gt 0 ]; then
      printf '  <key>WatchPaths</key>\n  <array>\n'
      local w
      for w in "${PLIST_WATCH[@]}"; do
        printf '    <string>%s</string>\n' "$(xml_escape "$w")"
      done
      printf '  </array>\n'
    fi

    if [ "${#PLIST_ENV[@]}" -gt 0 ]; then
      printf '  <key>EnvironmentVariables</key>\n  <dict>\n'
      local kv k v
      for kv in "${PLIST_ENV[@]}"; do
        k="${kv%%=*}"; v="${kv#*=}"
        printf '    <key>%s</key>\n    <string>%s</string>\n' \
               "$(xml_escape "$k")" "$(xml_escape "$v")"
      done
      printf '  </dict>\n'
    fi

    [ -n "${PLIST_INTERVAL:-}" ] && \
      printf '  <key>StartInterval</key>\n  <integer>%s</integer>\n' "$PLIST_INTERVAL"
    [ "${PLIST_KEEPALIVE:-0}" = "1" ] && printf '  <key>KeepAlive</key>\n  <true/>\n'
    [ "${PLIST_RUNATLOAD:-0}" = "1" ] && printf '  <key>RunAtLoad</key>\n  <true/>\n'
    [ -n "${PLIST_STDOUT:-}" ] && \
      printf '  <key>StandardOutPath</key>\n  <string>%s</string>\n' "$(xml_escape "$PLIST_STDOUT")"
    [ -n "${PLIST_STDERR:-}" ] && \
      printf '  <key>StandardErrorPath</key>\n  <string>%s</string>\n' "$(xml_escape "$PLIST_STDERR")"
    [ -n "${PLIST_PROCTYPE:-}" ] && \
      printf '  <key>ProcessType</key>\n  <string>%s</string>\n' "$(xml_escape "$PLIST_PROCTYPE")"
    if [ -n "${PLIST_NOFILE:-}" ]; then
      printf '  <key>SoftResourceLimits</key>\n  <dict>\n'
      printf '    <key>NumberOfFiles</key>\n    <integer>%s</integer>\n' "$PLIST_NOFILE"
      printf '  </dict>\n'
    fi

    printf '%s\n' '</dict>'
    printf '%s\n' '</plist>'
  } | write_and_verify "$dest" plutil -lint \
    || die "generated plist failed plutil -lint, $dest was not written"
}

xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  printf '%s' "$s"
}

gui_domain() { printf 'gui/%s\n' "$(id -u)"; }

# agent_loaded LABEL -> 0 if launchd knows about the job in this GUI domain.
agent_loaded() {
  launchctl print "$(gui_domain)/$1" >/dev/null 2>&1
}

# agent_load LABEL PLIST
#
# Idempotent. Boots the job out first if it is already there, because bootstrap on a
# loaded label fails with "service already loaded" and leaves the old program running.
agent_load() {
  local label="$1" plist="$2"
  [ -f "$plist" ] || die "no plist at $plist"
  if agent_loaded "$label"; then
    launchctl bootout "$(gui_domain)/$label" 2>/dev/null || true
  fi
  launchctl bootstrap "$(gui_domain)" "$plist" \
    || die "launchctl bootstrap failed for $label. Check: plutil -lint $plist"
}

# agent_unload LABEL. Succeeds whether or not the job is loaded.
agent_unload() {
  local label="$1"
  if agent_loaded "$label"; then
    launchctl bootout "$(gui_domain)/$label" 2>/dev/null || true
  fi
}

agent_kickstart() {
  launchctl kickstart -k "$(gui_domain)/$1" >/dev/null 2>&1
}

# agent_pid LABEL -> pid, or nothing when the job is loaded but not running.
agent_pid() {
  launchctl print "$(gui_domain)/$1" 2>/dev/null \
    | awk -F'= *' '/^[[:space:]]*pid =/ {print $2; exit}'
}

# agent_last_exit LABEL -> last exit code as launchd recorded it, or nothing.
agent_last_exit() {
  launchctl print "$(gui_domain)/$1" 2>/dev/null \
    | awk -F'= *' '/last exit code/ {print $2; exit}'
}

# agent_program LABEL -> first argv entry, which is how you tell an agent installed from
# this checkout from one installed from a different clone or an older scheme.
agent_program() {
  launchctl print "$(gui_domain)/$1" 2>/dev/null \
    | awk '/^[[:space:]]*arguments = \{/{f=1;next} f&&/\}/{exit} f{gsub(/^[[:space:]]+/,"");print;exit}'
}

# colliding_agents PATTERN
#
# Print loaded labels matching PATTERN that this repo did not install. Used by the
# installers to refuse when an older naming scheme is still loaded, since two agents
# doing the same job to the same files is the failure that goes unnoticed for weeks.
colliding_agents() {
  local pattern="$1"
  launchctl list 2>/dev/null | awk -v p="$pattern" '$3 ~ p {print $3}' \
    | grep -v "^$CCW_LABEL_PREFIX\." || true
}
