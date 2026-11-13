# Mise overview

An Omarchy bar widget for `mise dot` and `mise bootstrap`: see what changed on
origin, review it as a diff, and pull, publish, resolve, or bootstrap with a
confirmation.

It reads the configuration mise selects on the machine it runs on: your common
config plus whatever profile the machine declares (`MISE_ENV`). Every entry is
labelled with the scope it came from, so the same plugin works on any machine.

## What it shows

- **Bar:** a sync icon. A count appears when incoming changes, conflicts, or
  bootstrap changes need review; the icon turns urgent only for conflicts and
  failures. Right-click checks origin; middle-click re-reads local state.
- **Changes:** conflicts, incoming changes, changes to publish, unsaved edits,
  bootstrap drift, and changes on other profiles, each opening a per-file diff.
- **Sync:** origin, branch and mode, last pull and publish, automatic capture,
  and the automatic origin check toggle.
- **Browse:** tracked dotfiles by scope with per-file history, bootstrap
  resources grouped by kind, the checkpoint history with diffs, and the config
  files mise loaded.

## Actions

| Action | Where it runs | Safeguard |
| --- | --- | --- |
| Pull | In the panel | Confirmation; aborts if incoming changes differ from what you reviewed; undoable |
| Resolve conflicts | In the panel | Pick a version per file; same guard as pull; undoable |
| Publish | In the panel | Confirmation; reports when mise holds it back until you pull |
| Undo a pull | In the panel | Confirmation; only for the pull just made |
| Bootstrap | In a terminal | Fresh dry run, then asks before running |

Origin checks run `mise dot sync --fetch-only` every five minutes when enabled
(on by default). They never write files or push.

## Keyboard

`j`/`k` or arrows move, `Enter` activates, `l` opens, `h` or `Esc` goes back,
`r` checks origin, and `Tab` moves to the neighbouring bar panel.

Open a view directly, for example from a binding:

```sh
omarchy-shell fredrik.mise.view open incoming
```

Views: `home`, `incoming`, `outgoing`, `conflicts`, `local`, `other`,
`dotfiles`, `history`, `bootstrap`, `bootstrapRun`, `configs`,
`checkpoint:<id>`, `pathHistory:<~/path>`.

## Settings

`autoFetch` (default `true`) in the widget's `shell.json` entry, also toggled
from the panel.

## Development

`mise_dashboard.py` is the bounded adapter between the panel and mise. Diffs
against origin come from read-only `git` on mise's local history repository
with external diff drivers, textconv, and global and system git config disabled.

```sh
python3 -m unittest test_dashboard
omarchy plugin validate .
```

The fixture tests drive two machines sharing an origin through the real mise
CLI. After changing QML, run `omarchy restart shell`: plugin hot reload keeps
the cached `Dashboard` singleton.
