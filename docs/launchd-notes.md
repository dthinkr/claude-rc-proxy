# launchd notes

Everything in this repo that has to survive a Claude Code update runs as a launchd agent.
These are the things that cost real debugging time.

## A launchd job's PATH does not include /opt/homebrew/bin

This is the one that will get you. A script that works perfectly when you run it by hand
fails silently when launchd runs it, because `node`, `go`, `python3` from Homebrew are not
on the path launchd hands the job.

It cost an evening here. `open-binary`'s patcher verifies its own work with `node --check`
and rolls back if the check fails. Under launchd, `node` was not found, `node --check`
returned non-zero, and the script dutifully rolled back every single time. The log said
`FAIL node --check`. Running the same script in a terminal patched the bundle correctly.
The symptom was "the patch works when I install it and is gone the next morning".

Resolve every interpreter to an absolute path. `lib/common.sh` has `resolve_bin` for this,
and `./cc-kit doctor` prints what each one resolves to.

```sh
resolve_bin node /opt/homebrew/bin/node /usr/local/bin/node
```

Setting `PATH` inside the plist's `EnvironmentVariables` also works, but it hardcodes the
Homebrew prefix, which differs on Intel Macs.

## bootout, not unload

`launchctl unload` is the old syntax. It still works and it still prints nothing useful.

```sh
launchctl bootout gui/$(id -u)/io.github.dthinkr.ccw.open-binary
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.github.dthinkr.ccw.open-binary.plist
```

`bootout` returns non-zero when the job was not loaded, which is not an error in an
uninstall script. `lib/launchd.sh` swallows that specific case and nothing else.

To see whether a job is loaded and what it last exited with:

```sh
launchctl print gui/$(id -u)/io.github.dthinkr.ccw.open-binary | grep -E 'state|runs|last exit'
```

## WatchPaths fires on directory changes, and it is not the only watcher

`open-binary` watches `~/.vscode/extensions`. So do other tools. On the machine this repo
was written on there were three agents watching that one directory, and two of them patch
the same file, `webview/index.css`.

Both of those two wrote their backup to the same fixed name, `index.css.bak`, each guarded
by `[ -f "$CSS.bak" ] || cp`. Whichever ran second backed up a file the first had already
patched. Restoring that one backup silently reverted both patches. Nothing broke, because
each script re-applies itself on the next event, but the backup was worthless.

Two rules came out of that, and this repo follows both:

- Back up to a name that says which tool wrote it. `open-binary` uses
  `extension.js.ccw-open-binary.bak`, never `extension.js.bak`.
- Take a lock before read-modify-write on a vendor file. Two agents can fire on the same
  WatchPaths event in the same second.

`open-binary/install.sh` checks for other agents watching the extensions directory and
warns rather than refusing. Running another patcher alongside this one is a combination
nobody has tested.

## WatchPaths latency

A change to the watched directory fires the job within a second or two, not instantly.
When testing a self-heal path, restore the original file, touch something in the watched
directory, then poll for up to a minute before concluding the agent is broken.

```sh
touch ~/.vscode/extensions/.probe && rm ~/.vscode/extensions/.probe
```

## The plist is generated, not checked in

`lib/launchd.sh` writes the plist at install time with absolute paths baked in, pointing
into this checkout. That is why moving or deleting the checkout breaks the agents, and why
`git pull` is the whole update procedure.

If you install with a non-default setting, the value goes into the plist. Reading the
environment variable in your shell afterwards tells you nothing about what the agent is
running. `./cc-kit status` reads the plist.
