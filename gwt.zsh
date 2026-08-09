# Git worktree helpers: gwt / gwtc / gws (+ completions)
# Sourced from ~/.zshrc. Lives in ~/Scripts/gwt (own git repo) so it can be versioned.
#
# NOTE: helper functions callable at runtime (gwt_bootstrap) must NOT start
# with an underscore — Claude Code shell snapshots drop single-underscore
# function *definitions* while keeping call sites, which breaks under any
# agent shell. See README.md GOTCHA section. _gwt / _gws are fine: they are
# zsh completion functions, only ever invoked via `compdef`, never called
# directly by this script.
#
# gwt bootstraps every new worktree: worktrees carry only tracked files, so
# untracked .env* / .dev.vars* are copied over from the source worktree
# (skipping paths that already exist, node_modules and .git). If the repo has
# a secretspec.toml (https://secretspec.dev) and the CLI is installed, it runs
# `secretspec check` instead of relying on copied dotenv files alone.

# Copy untracked env files from the source worktree into a fresh one
gwt_bootstrap() {
  local src="$1" dst="$2"
  local f rel copied=0
  local -a env_files
  env_files=(${(f)"$(command find "$src" \
    \( -name node_modules -o -name .git \) -prune -o \
    \( -name '.env*' -o -name '.dev.vars*' \) -type f -print 2>/dev/null)"})

  for f in "${env_files[@]}"; do
    [[ -z "$f" ]] && continue
    rel="${f#$src/}"
    [[ -e "$dst/$rel" ]] && continue   # tracked files are already there
    mkdir -p "$dst/${rel:h}"
    if cp "$f" "$dst/$rel"; then
      echo "  env: $rel"
      (( copied++ ))
    fi
  done
  if (( copied > 0 )); then
    echo "Bootstrapped: copied $copied env file(s) from $(basename "$src")"
  fi

  if [[ -f "$dst/secretspec.toml" ]]; then
    if command -v secretspec >/dev/null 2>&1; then
      echo "secretspec.toml found — validating secrets:"
      ( cd "$dst" && secretspec check ) || \
        echo "  secretspec check failed — provision missing secrets (secretspec set <KEY>)"
    else
      echo "secretspec.toml found but secretspec is not installed (https://secretspec.dev)"
    fi
  fi

  echo "Remember: install deps (bun install / fvm flutter pub get) and run codegen if the repo needs it."
}

# Create git worktree next to repo root
gwt() {
  local branch="$1"
  local custom_name="$2"
  
  if [[ -z "$branch" ]]; then
    echo "Usage: gwt <branch-name> [custom-worktree-name]"
    echo ""
    echo "Examples:"
    echo "  gwt origin/feature-branch    # Create worktree from remote branch"
    echo "  gwt feature-branch           # Create worktree from existing local branch"
    return 1
  fi
  
  # Find git repo root
  local repo_root
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "Error: Not in a git repository"
    return 1
  }
  
  # Get repository parent directory and name
  local parent_dir repo_name
  parent_dir="$(dirname "$repo_root")"
  repo_name="$(basename "$repo_root")"
  
  # Determine if it's a remote or local branch by checking which ref exists.
  # Local branches can contain slashes (e.g. fix/foo), so a slash alone does
  # not mean it's a remote-tracking branch.
  local is_remote=0
  local branch_name="$branch"

  if git show-ref --verify --quiet "refs/heads/$branch"; then
    # Existing local branch (keep slashes as-is)
    is_remote=0
    branch_name="$branch"
  elif git show-ref --verify --quiet "refs/remotes/$branch"; then
    # Remote-tracking branch: strip the remote name (first path component)
    is_remote=1
    branch_name="${branch#*/}"
  else
    echo "Error: Branch '$branch' not found"
    echo "Available branches:"
    git branch -a | grep -v HEAD | head -20
    return 1
  fi
  
  # Check if local branch already exists when using remote
  if [[ $is_remote -eq 1 ]]; then
    if git rev-parse --verify --quiet "$branch_name" >/dev/null 2>&1; then
      echo "Local branch '$branch_name' already exists."
      read -q "REPLY?Use existing local branch? (y/N) "
      echo ""
      if [[ "$REPLY" != "y" && "$REPLY" != "Y" ]]; then
        return 1
      fi
      is_remote=0
      branch="$branch_name"
    fi
  fi
  
  # Determine worktree directory name
  local worktree_dir
  if [[ -n "$custom_name" ]]; then
    worktree_dir="${repo_name}-${custom_name}"
  else
    worktree_dir="${repo_name}-${branch_name//\//-}"
  fi
  
  # Full path for worktree
  local worktree_path="${parent_dir}/${worktree_dir}"
  
  # Verify path doesn't exist
  if [[ -e "$worktree_path" ]]; then
    echo "Error: Path already exists: $worktree_path"
    return 1
  fi
  
  # Create worktree
  echo "Creating worktree for $branch at $worktree_path"
  
  if [[ $is_remote -eq 1 ]]; then
    # Create new local branch from remote
    git worktree add -b "$branch_name" "$worktree_path" "$branch" || return 1
  else
    # Checkout existing local branch
    git worktree add "$worktree_path" "$branch" || return 1
  fi

  # Worktrees carry only tracked files — copy env files etc. from this worktree
  gwt_bootstrap "$repo_root" "$worktree_path"
}

# Zsh completion for gwt (includes both local and remote branches)
_gwt() {
  local -a branches
  
  # Get remote branches (strip leading spaces)
  branches=(${(f)"$(git branch -r 2>/dev/null | sed 's/^ *//' | grep -v HEAD)"})
  
  # Get local branches (strip leading spaces and current branch indicator)
  branches+=(${(f)"$(git branch 2>/dev/null | sed 's/^[* ] //' | grep -v HEAD)"})
  
  # Remove duplicates (in case a branch exists both locally and remotely)
  branches=(${(u)branches})
  
  _describe 'branch' branches
}

# Register completion (guarded: compdef only exists after compinit)
(( $+functions[compdef] )) && compdef _gwt gwt

# Cleanup merged worktrees, but protect worktrees with uncommitted changes
#
# Options:
#   -n, --dry-run        Show what would be removed
#   -y, --yes            Don’t prompt
#   -F, --force          Pass --force to `git worktree remove`
#   -b, --base <branch>  Compare against this branch (default: current branch)
#   --include-dirty      ALSO remove dirty worktrees (dangerous; use with -F)
#   --delete-branch      Also delete the local branch after removing the worktree
gwtc() {
  emulate -L zsh
  setopt pipefail

  local dry=0 yes=0 force=0 delete_branch=0 include_dirty=0 base=""
  while (( $# > 0 )); do
    case "$1" in
      -n|--dry-run) dry=1 ;;
      -y|--yes) yes=1 ;;
      -F|--force) force=1 ;;
      -b|--base)
        base="$2"
        shift
        ;;
      --include-dirty) include_dirty=1 ;;
      --delete-branch) delete_branch=1 ;;
      *)
        echo "Usage: gwtc [-n|--dry-run] [-y|--yes] [-F|--force] [-b|--base <branch>] [--include-dirty] [--delete-branch]" >&2
        return 2
        ;;
    esac
    shift
  done

  git rev-parse --show-toplevel >/dev/null 2>&1 || {
    echo "Error: Not in a git repository" >&2
    return 1
  }

  local current_toplevel current_branch
  current_toplevel="$(git rev-parse --show-toplevel)" || return 1
  current_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || {
    echo "Error: detached HEAD. Use: gwtc --base <branch>" >&2
    return 1
  }

  [[ -z "$base" ]] && base="$current_branch"

  git rev-parse -q --verify "$base" >/dev/null 2>&1 || {
    echo "Error: base '$base' does not resolve to a commit/ref" >&2
    return 1
  }

  local -a rm_paths rm_branches
  local -a skip_dirty_paths skip_dirty_branches
  local -a skip_bad_paths skip_bad_branches

  local wt_path="" wt_branch_ref="" wt_locked=0 wt_prunable=0 line=""

  flush_entry() {
    if [[ -n "$wt_path" && -n "$wt_branch_ref" && "$wt_branch_ref" == refs/heads/* ]]; then
      local b="${wt_branch_ref#refs/heads/}"

      # Never remove the worktree you're currently in
      if [[ "$wt_path" == "$current_toplevel" ]]; then
        wt_path=""; wt_branch_ref=""; wt_locked=0; wt_prunable=0
        return
      fi

      # Don’t remove base branch worktree
      if [[ "$b" == "$base" ]]; then
        wt_path=""; wt_branch_ref=""; wt_locked=0; wt_prunable=0
        return
      fi

      # Only consider it if the worktree branch tip is merged into base
      if git merge-base --is-ancestor "$wt_branch_ref" "$base" >/dev/null 2>&1; then
        # Skip locked/prunable/unverifiable entries (safe default)
        if (( wt_locked == 1 || wt_prunable == 1 )); then
          skip_bad_paths+=("$wt_path")
          skip_bad_branches+=("$b")
          wt_path=""; wt_branch_ref=""; wt_locked=0; wt_prunable=0
          return
        fi

        # Verify we can run git in that worktree and check dirtiness
        if ! git -C "$wt_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
          skip_bad_paths+=("$wt_path")
          skip_bad_branches+=("$b")
          wt_path=""; wt_branch_ref=""; wt_locked=0; wt_prunable=0
          return
        fi

        local st
        st="$(git -C "$wt_path" status --porcelain 2>/dev/null)" || st="__FAILED__"

        if [[ "$st" != "" && "$st" != "__FAILED__" ]]; then
          # dirty
          if (( include_dirty == 0 )); then
            skip_dirty_paths+=("$wt_path")
            skip_dirty_branches+=("$b")
          else
            rm_paths+=("$wt_path")
            rm_branches+=("$b")
          fi
        elif [[ "$st" == "__FAILED__" ]]; then
          skip_bad_paths+=("$wt_path")
          skip_bad_branches+=("$b")
        else
          # clean
          rm_paths+=("$wt_path")
          rm_branches+=("$b")
        fi
      fi
    fi

    wt_path=""
    wt_branch_ref=""
    wt_locked=0
    wt_prunable=0
  }

  while IFS= read -r line; do
    if [[ -z "$line" ]]; then
      flush_entry
      continue
    fi

    case "$line" in
      worktree\ *) wt_path="${line#worktree }" ;;
      branch\ *) wt_branch_ref="${line#branch }" ;;
      locked*) wt_locked=1 ;;
      prunable*) wt_prunable=1 ;;
    esac
  done < <({ git worktree list --porcelain; echo; } 2>/dev/null)

  if (( ${#rm_paths} == 0 )); then
    echo "No removable merged worktrees found (base: '$base')."
    if (( ${#skip_dirty_paths} > 0 )); then
      echo "Skipped (dirty):"
      local i
      for (( i = 1; i <= ${#skip_dirty_paths}; i++ )); do
        echo "  - ${skip_dirty_paths[$i]} (branch: ${skip_dirty_branches[$i]})"
      done
    fi
    if (( ${#skip_bad_paths} > 0 )); then
      echo "Skipped (locked/prunable/unverifiable):"
      local i
      for (( i = 1; i <= ${#skip_bad_paths}; i++ )); do
        echo "  - ${skip_bad_paths[$i]} (branch: ${skip_bad_branches[$i]})"
      done
      echo "Tip: run `git worktree prune` to clean up prunable/stale entries."
    fi
    return 0
  fi

  echo "Will remove merged worktrees (base: '$base'):"
  local i
  for (( i = 1; i <= ${#rm_paths}; i++ )); do
    echo "  - ${rm_paths[$i]} (branch: ${rm_branches[$i]})"
  done

  if (( ${#skip_dirty_paths} > 0 )); then
    echo "Skipped (dirty):"
    for (( i = 1; i <= ${#skip_dirty_paths}; i++ )); do
      echo "  - ${skip_dirty_paths[$i]} (branch: ${skip_dirty_branches[$i]})"
    done
    echo "Use --include-dirty (and usually -F) if you really want to remove them."
  fi

  if (( dry == 1 )); then
    return 0
  fi

  if (( yes == 0 )); then
    echo ""
    read -q "REPLY?Proceed? (y/N) "
    echo ""
    [[ "$REPLY" == [yY] ]] || { echo "Cancelled."; return 0; }
  fi

  local -a rm_args
  rm_args=(worktree remove)
  (( force == 1 )) && rm_args+=(--force)

  local failed=0
  for (( i = 1; i <= ${#rm_paths}; i++ )); do
    echo "Removing worktree: ${rm_paths[$i]}"
    if ! git "${rm_args[@]}" -- "${rm_paths[$i]}"; then
      echo "  Failed. Try: git worktree remove --force -- '${rm_paths[$i]}'" >&2
      failed=1
      continue
    fi

    if (( delete_branch == 1 )); then
      git branch -d -- "${rm_branches[$i]}" >/dev/null 2>&1 || true
    fi
  done

  git worktree prune >/dev/null 2>&1 || true
  return $failed
}

# Switch to another worktree, preserving your relative subdirectory
# Usage: gws <branch-name>
# If the same subdirectory doesn't exist in the target, lands at the worktree root
gws() {
  local branch="$1"
  
  if [[ -z "$branch" ]]; then
    echo "Usage: gws <branch-name>"
    echo ""
    echo "Examples:"
    echo "  gws feature-branch     # Switch to feature-branch worktree"
    echo "  gws origin/hotfix      # Works with remote prefix too"
    return 1
  fi
  
  # Get current worktree root
  local current_root
  current_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "Error: Not in a git repository"
    return 1
  }
  
  # Calculate relative path from current worktree root
  local rel_path=""
  if [[ "$PWD" != "$current_root" ]]; then
    rel_path="${PWD#$current_root/}"
  fi
  
  # Find target worktree path by branch name
  local target_path=""
  
  # Try exact match
  target_path="$(git worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$branch" '
    $1 == "worktree" { path = $2 }
    $1 == "branch" && $2 == b { print path; exit }
  ')"
  
  # If not found and looks like remote/branch, try stripping the remote prefix
  if [[ -z "$target_path" && "$branch" == */* ]]; then
    local short_branch="${branch#*/}"
    target_path="$(git worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$short_branch" '
      $1 == "worktree" { path = $2 }
      $1 == "branch" && $2 == b { print path; exit }
    ')"
  fi
  
  if [[ -z "$target_path" ]]; then
    echo "Error: No worktree found for branch '$branch'"
    echo ""
    echo "Available worktrees:"
    git worktree list | sed 's/^/  /'
    return 1
  fi
  
  # Don't switch if already there
  if [[ "$target_path" == "$current_root" ]]; then
    echo "Already in worktree for '$branch'"
    return 0
  fi
  
  # Determine destination: same subdir if it exists, else worktree root
  local dest="$target_path"
  if [[ -n "$rel_path" ]]; then
    if [[ -d "$target_path/$rel_path" ]]; then
      dest="$target_path/$rel_path"
    else
      echo "Note: './$rel_path' not found in target, landing at worktree root"
    fi
  fi
  
  cd "$dest" || return 1
}

# Completion: only suggest branches that have worktrees
_gws() {
  local -a branches
  branches=(${(f)"$(git worktree list --porcelain 2>/dev/null | awk '/^branch refs\/heads\//{sub(/^branch refs\/heads\//,""); print}')"})
  _describe 'branch' branches
}

(( $+functions[compdef] )) && compdef _gws gws

# Ensure sourcing this file does not leak a non-zero exit status
true
