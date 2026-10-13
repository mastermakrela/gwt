#!/usr/bin/env zsh
# Smoke tests for gwt.zsh. Run: zsh test.zsh
# Builds throwaway repos in a temp dir; touches no real repo or git config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

source "${0:A:h}/gwt.zsh"

T="$(mktemp -d)"; T="${T:A}"   # :A resolves /tmp -> /private/tmp like git does
trap 'rm -rf "$T"' EXIT
fails=0
check() {  # check <description> <command...>
  local desc="$1"; shift
  if "$@"; then echo "ok   $desc"; else echo "FAIL $desc"; (( fails++ )); fi
}
has() { [[ "$1" == *"$2"* ]]; }

git init -q -b main "$T/repo" && cd "$T/repo" && git commit -q --allow-empty -m init

# gwtc --dry-run must not touch anything (a prunable worktree stays prunable)
git worktree add -q ../repo-gone -b gone && rm -rf ../repo-gone
out="$(gwtc -n 2>&1)"
check "gwtc -n lists the prunable worktree" has "$out" "repo-gone"
check "gwtc -n does not prune" has "$(git worktree list)" "prunable"
git worktree prune; git branch -q -D gone

# gwt names worktrees after the main worktree, also when run from a linked one
git branch b1; git branch b2
gwt b1 >/dev/null 2>&1
( cd "$T/repo-b1" && gwt b2 >/dev/null 2>&1 )
check "gwt b1 creates ../repo-b1" test -d "$T/repo-b1"
check "gwt from a linked worktree creates ../repo-b2" test -d "$T/repo-b2"

# gws finds worktrees whose path contains a space
git worktree add -q "$T/has space" -b sp
gws sp >/dev/null 2>&1
check "gws enters 'has space'" test "$PWD" = "$T/has space"
cd "$T/repo"

# gwtc: with -b <feature> that contains main, the main worktree is never offered
git -C "$T/repo-b1" commit -q --allow-empty -m feature
git branch b4; gwt b4 >/dev/null 2>&1
out="$(cd "$T/repo-b2" && gwtc -n -b b1 2>&1)"   # from a linked worktree, so main is not "current"
check "gwtc lists a merged worktree" has "$out" "(branch: b4)"
check "gwtc never offers the main worktree" test "${out/(branch: main)/}" = "$out"

# dirty worktrees are skipped
git worktree add -q ../repo-dirty -b dirty && echo x > ../repo-dirty/x
out="$(gwtc -n 2>&1)"
check "dirty worktree is skipped" has "$out" "Skipped (dirty)"
git worktree remove -f ../repo-dirty; git branch -q -D dirty

# gwtc -b works from a detached HEAD; -b without a value is an error
git checkout -q --detach
gwtc -n -b main >/dev/null 2>&1; check "gwtc -b main works on detached HEAD" test $? -eq 0
check "gwtc without -b fails on detached HEAD" test "$(gwtc -n 2>&1 >/dev/null)" != ""
gwtc -n -b >/dev/null 2>&1; check "gwtc -b without a value returns 2" test $? -eq 2
git checkout -q main

# --delete-branch removes the branch even when HEAD is not the base
git worktree add -q ../repo-m -b merged && git -C ../repo-m commit -q --allow-empty -m m
git merge -q --ff-only merged
git checkout -q -b elsewhere main~1
gwtc -y -b main --delete-branch >/dev/null 2>&1
check "--delete-branch deleted 'merged'" test -z "$(git branch --list merged)"
git checkout -q main

# gwt_bootstrap copies ignored env files, never *.example
echo '.env*' > .gitignore; git add .gitignore; git commit -q -m ign
echo SECRET > .env; echo x > .env.example
git branch b3; gwt b3 >/dev/null 2>&1
check "bootstrap copies .env" test -f "$T/repo-b3/.env"
check "bootstrap skips .env.example" test ! -e "$T/repo-b3/.env.example"

echo; (( fails == 0 )) && echo "all passed" || echo "$fails failed"
exit $(( fails > 0 ))
