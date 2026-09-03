# Prior art

What other people did first, and what is actually new here. Written so nobody has to
take the repo's word for its own novelty.

## The binary file link bug was reported, diagnosed, and closed

The symptom has at least eight issues on `anthropics/claude-code`: #10846, #37989, #41112,
#51015, #57100, #72889, and more. They form one duplicate chain.

**#37989, opened 2026-03-23, already got the cause and the fix right.** It says the
extension "likely routes link clicks through `vscode.workspace.openTextDocument()` which
silently fails for binary files", and proposes routing image files through
`vscode.commands.executeCommand('vscode.open', uri)`.

That is this repo's fix, described publicly five months before this repo existed. This
repo did not discover the cause. Anyone who says otherwise, including an earlier draft of
this README, is wrong.

Both #37989 and #72889 were closed as `not planned` carrying a `stale` label.

## Those closures were a bot, not a decision

`scripts/sweep.ts` and `scripts/issue-lifecycle.ts` in that repo are public.
`STALE_UPVOTE_THRESHOLD = 10`, and an issue labelled `stale` closes 14 days later with
`state_reason: not_planned`. Four things exempt it: ten or more `+1` reactions, a comment
from a non-bot account after the label was applied, an assignee, or a locked thread.
#72889 died with eight reactions.

So "closed as not planned" here does not mean anyone read it and decided against it. It
also means a single human comment keeps an issue alive for another cycle.

The repo contains no product source, so there is no pull request path. Issues are the only
channel.

## What is new here

Four things, and they are narrower than "we fixed it".

1. **The cause is verified rather than guessed.** #37989 said "likely". This repo names
   the call site in the shipped bundle and the exact shape of the defect: the `.then()`
   has a success callback and no rejection handler. The rejection happens at the
   document-model layer, inside `workspace.openTextDocument`, before any editor exists.
   That is why no editor setting can work around it, which several people have tried.

2. **The NUL-byte rule.** The discriminator is whether the first 512 bytes contain a NUL,
   not the file type. It explains the thing that made the bug look random: some binaries
   do nothing at all, others open as a text tab full of mojibake. #37989 discusses PNG.
   #51015 discusses mp4. Nobody connected the two failure modes to one rule.

3. **The webview allowlist defect**, which is separate, which this repo cannot fix, and
   which appears not to be reported anywhere. See `tools/open-binary/README.md`.

4. **A working patch.** None of the sixteen issues in the chain contains a patch, a script
   or a code fix in any comment. The workarounds offered there are Cmd+P quick open,
   `open -R` from a Bash tool call, and revealing the file in the Explorer by hand.

## Patching a vendor bundle is an old genre

Patching VS Code itself has been done for over a decade. Custom CSS and JS Loader,
Vibrancy Continued and APC Customize UI++ each have hundreds to a thousand stars, and
`lehni/vscode-fix-checksums` exists because VS Code notices when you do it.

Patching a *third-party extension's* bundle is rarer but not new either.
`subframe7536/vscode-custom-ui-style` does it generically, and its documented example is
`github.copilot-chat`'s `dist/extension.js`.

Roughly eight tools already patch `anthropic.claude-code` specifically. Two of them,
`ojhurst/claude-code-vscode-patcher` and `Blake-C/claude-overwrite-features-vscode`,
independently arrived at the same architecture used here: a launchd agent with WatchPaths
on `~/.vscode/extensions`, regexes anchored on stable string literals with the minified
identifiers wildcarded, idempotent self-detecting patches, and `.bak` backups.

None of them touches the `openFile` click handler. That was checked per repo, searching
each for `openFile`, `showTextDocument`, `revealInExplorer` and `vscode.open`. Zero hits.

What this repo adds to that genre is small and worth stating plainly: `node --check` on
the patched bundle with automatic rollback when it fails, and recovering the minified
variable names from the structure of the surrounding code rather than pinning them, so the
patch survives re-minification across releases.

## rc-proxy and auto-compact

No prior art was found for either, which is weaker evidence than it sounds. Both solve
problems that only appear once you are doing something unusual, so the population of
people who would have published a fix is small.
