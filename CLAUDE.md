# Working on this repo

Two Swift files, no package manager. `./build.sh` produces
`build/ClaudeContextMonitor.app` containing both binaries; `./install.sh` builds,
copies it to `~/Applications` and calls `./setup.sh`, which is the only part that
touches Claude Code's own configuration.

- `src/app.swift` — the menu bar app.
- `src/statusline.swift` — `cc-widget-statusline`, the collector Claude Code runs
  as a status line. It caches to `~/.claude/widget-cache/`.

`ClaudeContextMonitor --print` dumps the same data as text and is the fastest way
to check the collector without the menu.

## Invariants

These were each arrived at by being wrong first. Changing one means re-deciding
something, not fixing an oversight.

**Rate limits come only from the status line JSON.** They are not cached under
`~/.claude` and there is no `claude usage` subcommand. Any other route means
reading the OAuth token out of the keychain — don't.

**`~/.claude/sessions/*.json` is the only source of which sessions exist.** An
earlier version also discovered sessions from recently modified transcripts.
That could not tell an idle session from an ended one, so a desktop session
lingered for thirty minutes after its app was quit. Missing a front-end that
registers nothing is the better failure.

**Report what is known, don't infer.** The CLI writes a `status` field; other
front-ends do not. A session without one is shown as unknown (`◌`) and left out
of the busy/idle ratio rather than assumed idle.

**Exclude `isSidechain` records when reading a transcript.** Those are subagent
turns with their own context; counting them makes a session's usage collapse.

**The `[1m]` suffix only appears in the model attachment.** A transcript's
`message.model` says `claude-opus-5` even in a 1M session, so the context window
must come from the status line's `context_window_size` or that attachment.

## Traps

**`ps` column padding.** `split(maxSplits:)` returns the remainder verbatim, so
the command column arrives with the spaces `ps` used to align it. Untrimmed, a
path is read as relative and resolves nowhere.

**A menu item cannot both run an action and open a submenu.** Session rows act
on click; their details live on an Option-held alternate item.

**`NSAppleScript` runs on a serial background queue**, never the main thread — a
wedged terminal must not freeze the menu bar.

**Stop the service before replacing the bundle.** `launchctl bootstrap` fails
with `Input/output error` if the program was deleted while the job was loaded.

**Bundle identifier and `autosaveName` are user-visible state.** Changing either
loses the menu bar icon position and the granted TCC permissions. A rebuild
already re-signs the app, so macOS re-asks for automation access after updates.

## Testing

Run it. Every bug in the history was found by driving the real app, not by
reading the code:

    ./install.sh && ClaudeContextMonitor --print

Useful checks: compare the session count against `ls ~/.claude/sessions/*.json`,
read the menu bar title through System Events, and watch
`~/.claude/widget-cache/limits.json` update while a session renders.

Do not fake data by writing into `~/.claude/sessions/` or a real transcript.
Write a synthetic transcript under a throwaway project directory and delete it,
or temporarily edit `widget-cache/limits.json`, which the collector overwrites on
the next render.

## Releasing

Tag, release, then point the tap at the new tarball:

    git tag -a vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z
    gh release create vX.Y.Z --title vX.Y.Z --notes "..."
    # in ../homebrew-tap: bump url and sha256, commit, push
    brew update && brew upgrade claude-context-monitor

The launch agent points at Homebrew's `opt` path, which survives version bumps;
the Cellar path would not.
