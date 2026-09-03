# Conventions

Rules every tool here follows. They exist so that uninstalling actually uninstalls, and so
that a reader can predict where a tool put things without reading its source.

## Names

| Thing | Form | Example |
|---|---|---|
| Repo | `claude-code-workarounds` | searched for by problem, not by brand |
| CLI | `cc-kit` | short because you type it |
| launchd label | `io.github.dthinkr.ccw.<tool>` | `io.github.dthinkr.ccw.open-binary` |
| State directory | `~/.local/state/ccw/<tool>/` | logs, caches, anything regenerable |
| Config | `~/.config/ccw/<tool>.*` | only when a secret has to live somewhere |
| Backup of a vendor file | `<original>.ccw-<tool>.bak` | `extension.js.ccw-open-binary.bak` |

Nothing is written under `~/.claude/`. That directory belongs to Anthropic and a future
version may well clean it.

The backup name carries the tool name on purpose. Two tools that back up the same vendor
file to the same generic `.bak` will silently destroy each other's rollback. That has
already happened on the machine this was written on. See `launchd-notes.md`.

## The four verbs

Every tool implements the same four, and `cc-kit` dispatches to them:

- `doctor` writes nothing. It reports what it found and what it would need.
- `install` prints what it will change, then changes it.
- `status` answers "is this working right now", not "did I run install once".
- `uninstall` restores the original state and says what it could not restore.

`diff` and `nul-scan` exist only for `open-binary`, because only that tool edits a file
you did not write.

## Refuse loudly, never degrade quietly

If a tool cannot do the thing it was asked to do, it fails and says why. It does not do a
smaller thing and report success.

Concretely:

- The patcher runs `node --check` on the result and restores the backup if it fails. If
  `node` cannot be found it refuses rather than skipping the check.
- `auto-compact` refuses to overwrite a `claudeCode.claudeProcessWrapper` that points
  somewhere outside this checkout, because that is somebody else's tool.
- `rc-proxy` routes inference to an unreachable address when no pool token is set, so a
  misconfiguration fails instead of quietly spending subscription quota.
- Installers refuse when they find a launchd agent from another tool that manages the same
  file.

## Absolute paths in anything launchd runs

A launchd job's PATH does not include `/opt/homebrew/bin`. Every interpreter is resolved
with `resolve_bin` from `lib/common.sh` and written into the plist as an absolute path.
`./cc-kit doctor` prints what each resolved to.

## Manifests

Each tool has a `manifest.conf` listing every path it writes and the command that undoes
it. `lib/manifest.sh` reads them, and `docs/what-this-touches.md` is generated from them
by `./cc-kit manifest-doc`.

A hand-written list of touched paths goes stale silently, which is exactly the failure a
reader of a repo like this cannot afford. If a tool writes a path, it goes in the manifest
or `uninstall` will not remove it.

## Shell

`bash`, targeting the 3.2 that ships with macOS, so no associative arrays and no `${x^^}`.
`set -u`, and explicit error checks rather than `set -e`, because these scripts need to
report what failed rather than vanish.

Every script is `shellcheck` clean and passes `bash -n`.

## Prose

No em dashes. No "not X, but Y". No appositive explainers hung off a noun. American
spelling. If something is uncertain, the text says so rather than hedging with adverbs.
