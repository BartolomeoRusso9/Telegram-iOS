#!/bin/bash
# Merges an upstream commit into a NEW branch, never into the customized branch itself.
# Nothing is force-pushed or rebased, so history stays linear to recover: an unwanted sync is a
# branch to delete or a merge to revert.
#
#   upstream-merge.sh <upstream-ref> <new-branch>
#
# Exit status: 0 merged, 3 nothing to do, 4 conflicts that need a person (the merge is aborted
# and the conflicted paths are written to $CONFLICTS_FILE).
set -euo pipefail

UPSTREAM_REF="$1"
NEW_BRANCH="$2"
CONFLICTS_FILE="${CONFLICTS_FILE:-/tmp/cast-upstream-conflicts.txt}"

if git merge-base --is-ancestor "$UPSTREAM_REF" HEAD; then
    echo "Already contains $UPSTREAM_REF"
    exit 3
fi

git switch -c "$NEW_BRANCH"

# rerere replays resolutions a person already made and committed to .rr-cache; it never guesses.
git config rerere.enabled true
git config rerere.autoupdate true

if git merge --no-ff --no-edit -m "Merge upstream $(git rev-parse --short "$UPSTREAM_REF")" "$UPSTREAM_REF"; then
    exit 0
fi

if [ -z "$(git diff --name-only --diff-filter=U)" ]; then
    git commit --no-edit
    echo "All conflicts resolved from recorded resolutions"
    exit 0
fi

git diff --name-only --diff-filter=U | tee "$CONFLICTS_FILE"
git merge --abort
exit 4
