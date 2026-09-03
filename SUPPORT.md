# Support

These tools are unsupported. I wrote them for my own machine and published them because the
bugs they work around are real and I could not find a published fix for any of them. Other
people have patched this extension for other reasons, and
[docs/prior-art.md](docs/prior-art.md) names them and says what is actually new here. Each
tool edits or intercepts software I do not control, so any of them can stop working on a
release I did not see coming. Read
[What breaks, and when](README.md#what-breaks-and-when) before you install anything.

macOS only. There is no Linux or Windows version and there will not be one. The
installers use launchd and macOS paths throughout.

## Before you open an issue

Run both of these and paste the output:

```sh
./cc-kit doctor
./cc-kit status
```

Add the log for the tool you are reporting:

- `open-binary`: the last 20 lines of `~/.local/state/ccw/open-binary/patch.log`
- `auto-compact`: the last 50 lines of `~/.local/state/ccw/auto-compact/compactd.log`
- `rc-proxy`: the three probe results from `./cc-kit status rc-proxy`

Two things to rule out first. For `open-binary`, run `Developer: Reload Window` in VS
Code. A loaded agent and a patched bundle change nothing until the window reloads. For
`auto-compact`, check that `claudeCode.claudeProcessWrapper` points at the checkout you
are running from, and that VS Code restarted after the setting was written.

## What I will look at

- The patch anchor stopped matching after an extension release. Include the extension
  version and the output of `./cc-kit diff open-binary`. This is the expected maintenance
  work and it is most of why the repo exists.
- An installer wrote a path that is not listed in
  [docs/what-this-touches.md](docs/what-this-touches.md). That is a bug. Say so plainly.
- Anything in the docs that is false on your machine. The measurements here come from one
  Mac and some of them are properties of individual files rather than of formats.

## What I will not do

- Port any of this to Linux or Windows.
- Make `rc-proxy` work with a gateway I cannot run locally.
- Support combinations with other tools that patch the same files. Two patchers that back
  up to the same filename can silently undo each other. See
  [docs/launchd-notes.md](docs/launchd-notes.md).
- Add a second way to do something `cc-kit` already does.

If Anthropic fixes one of these upstream, tell me. I will archive that tool rather than
keep patching around a fix.

## Pull requests

Small ones are welcome. Four rules.

CI must pass. `.github/workflows/check.yml` runs shellcheck, `bash -n`, `py_compile`,
`go vet`, `go test`, a prose check, and a check that no CJK characters came back in.

No new dependencies. `go.mod` declares none. Every Python file here imports the standard
library only, and the shim runs under `/usr/bin/python3`, so nothing may need a newer
Python than the one macOS ships.

No fragment of Anthropic's bundle in the tree. Test against your own installed copy with
`./cc-kit diff open-binary`. A checked-in fixture goes stale within about a week at the
current release cadence, and it redistributes someone else's code.

Prose follows the same rules as the rest of the repo. No em dashes, plain sentences, and
say what a thing costs the reader. The CI prose check covers the mechanical part.
