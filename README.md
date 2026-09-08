# gwt.zsh — git worktree helpers

Zsh functions `gwt`, `gwtc`, `gws` for working with git worktrees, plus
completion functions `_gwt` / `_gws`.

## Commands

### `gwt <branch-name> [custom-worktree-name]`

Create a git worktree from an existing local or remote branch, placed next
to the repo root as `../<repo>-<branch>` (or `../<repo>-<custom-name>` if
given). Examples from the script's own usage text:

```
gwt origin/feature-branch    # Create worktree from remote branch
gwt feature-branch           # Create worktree from existing local branch
```

- A remote branch (`origin/foo`) creates a new local tracking branch `foo`.
- If that local branch already exists, you're prompted whether to reuse it.
- After creating the worktree, `gwt_bootstrap` runs automatically: it copies
  any untracked `.env*` / `.dev.vars*` files from the source worktree into
  the new one (skipping paths that already exist, `node_modules`, and
  `.git`), and if the repo has a `secretspec.toml` and the `secretspec` CLI
  is installed, runs `secretspec check` instead of/in addition to relying on
  copied dotenv files.
- It does **not** install dependencies or run codegen — you still need
  `bun install` / `fvm flutter pub get` and any codegen step yourself.

### `gwtc [-n|--dry-run] [-y|--yes] [-F|--force] [-b|--base <branch>] [--include-dirty] [--delete-branch]`

Clean up worktrees whose branch is already merged into a base branch
(default: the current branch), while protecting the current worktree, the
base branch's worktree, and any worktree with uncommitted changes.

- `-n`, `--dry-run` — show what would be removed, do nothing.
- `-y`, `--yes` — don't prompt for confirmation.
- `-F`, `--force` — pass `--force` to `git worktree remove`.
- `-b`, `--base <branch>` — compare against this branch instead of the
  current one.
- `--include-dirty` — also remove worktrees with uncommitted changes
  (dangerous; normally combined with `-F`).
- `--delete-branch` — also delete the local branch after removing its
  worktree.

Typical usage: run `gwtc -n` first to preview, then `gwtc -y` to apply.

### `gws <branch-name>`

Switch to the worktree for `<branch-name>`, preserving your current
relative subdirectory if that subdirectory exists in the target worktree
(otherwise lands at the target's root).

```
gws feature-branch     # Switch to feature-branch worktree
gws origin/hotfix      # Works with remote prefix too
```

## Wiring

`~/.zshrc` sources this file:

```
[ -f "$HOME/Scripts/gwt/gwt.zsh" ] && source "$HOME/Scripts/gwt/gwt.zsh"
```

This directory is its own git repo (not part of `~/Scripts`, which isn't
versioned) so changes to these helpers have history.

## GOTCHA: no underscore-prefixed functions callable at runtime

Claude Code snapshots the interactive shell into
`~/.claude/shell-snapshots/snapshot-zsh-*.sh` and sources that snapshot
instead of `~/.zshrc` when running non-interactively (e.g. inside an
agent). That snapshot mechanism **drops function *definitions* whose name
starts with a single underscore, while keeping any call sites that
reference them.**

Concretely, this file used to define a `_gwt_bootstrap` helper called from
inside `gwt()`. Under a snapshot-sourced shell, the call site survived but
the definition didn't, so `gwt` would create the worktree and then fail
with `command not found: _gwt_bootstrap` — silently skipping the `.env`
copy and `secretspec check` step, with no obvious error tying it back to
the snapshot. It was renamed to `gwt_bootstrap`.

**Rule going forward:** any function in this file that is called directly
(not just registered via `compdef`) must NOT start with `_`. The
single-underscore convention is reserved for `_gwt` / `_gws`, the zsh
completion functions — those are safe to keep prefixed because they are
only ever invoked through `compdef` (itself guarded by
`(( $+functions[compdef] ))`), never called directly by this script, so
losing them under a snapshot-sourced agent shell is harmless (you just lose
tab-completion, which doesn't exist in a non-interactive shell anyway).

## GOTCHA: `compdef` exists in the snapshot, `_comps` does not

The same snapshot captures the `compdef` *function* (because `compinit` ran
in the interactive shell), but not the `_comps` associative array that
`compinit` creates. So inside an agent shell `(( $+functions[compdef] ))`
is true, `compdef _gwt gwt` runs, and dies with

```
compdef:153: _comps: assignment to invalid subscript range
```

That is a fatal error for the sourced file: everything after the first
`compdef` line (`gwtc`, `gws`, `_gws`) is never defined and `source` returns
126, so `source ~/Scripts/gwt/gwt.zsh && gwt …` never reaches `gwt`.

**Rule going forward:** guard completion registration on both:
`(( $+functions[compdef] && $+_comps )) && compdef …`.
