#!/usr/bin/env bash
#
# verify-tag-source.sh — the tag guard.
#
# One check and one warning on the tag itself, then two gates on the commit.
#
#   T-3     the tag name. The name must be vMAJOR.MINOR.PATCH.
#   T-2     the tag object. A lightweight tag gives a warning. It does not stop the
#           release. The Releases page on GitHub makes a lightweight tag, so a refusal
#           here would block each release that starts on that page.
#   Gate 2  ancestry. The tip of the release branch must contain the commit. This gate
#           also gives the diagnostics on a refusal: it reports how many commits the
#           tagged commit holds that the release branch does not hold.
#   Gate 3  the release line. The commit must be on the first-parent line of the release
#           branch. This gate makes the decision.
#
# There is no gate 1. An earlier gate 1 read the set of branches that hold the commit,
# and it demanded the name of the release branch alone. That set is not a property of
# the release. It grows when a person cuts a branch off the release branch, and it does
# not shrink until that branch is deleted. The same commit, with the same tag, still the
# tip of `main`, gave PERMIT before a colleague cut `feature/x` and REFUSE after. A gate
# that refuses a correct release is a gate that a person bypasses in an incident, and
# that outcome is worse than the outcome that the gate stops.
#
# Gate 3 needs no such set. The first-parent line of `main` is the line of `main` itself.
# A tag on `dev` is not on that line. A tag on the tip of a branch that a person merged
# is a second parent, so it is not on that line either. Both are refused.
#
# This is the control that stops the 14 July 2026 incident. In that incident a build
# from `dev` went to production, because the release workflow accepted each branch that
# the operator selected.
#
# Usage:  scripts/verify-tag-source.sh <tag-or-commit> [release-branch]
#
# Exit 0 — each check and each gate passes. The release can continue.
# Exit 1 — one check or one gate fails. Refuse the release.

set -euo pipefail

COMMIT="${1:?usage: verify-tag-source.sh <tag-or-commit> [release-branch]}"
RELEASE_BRANCH="${2:-main}"
REMOTE="${GUARD_REMOTE:-origin}"

# fail() also writes the reason to the step output when a workflow runs the script. The
# `revoke` job reads that reason, so the issue that it opens names the check that refused
# the tag. Without this, each issue gave one generic reason for each cause.
fail() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "reason=$1" >> "$GITHUB_OUTPUT"
  fi
  printf '\n\033[31m✗ RELEASE BLOCKED\033[0m — %s\n\n' "$1" >&2
  exit 1
}
ok()   { printf '\n\033[32m✓ RELEASE PERMITTED\033[0m — %s\n\n' "$1"; exit 0; }

# has_line <list> <line> — is the line in the list, as a full line?
#
# This function uses no pipe. A pipe into `grep -q` is not reliable here. `grep -q`
# exits at the first match, the process on the left of the pipe then writes to a closed
# pipe, and `set -o pipefail` reads the SIGPIPE as a failure. The result depends on the
# time that each process takes.
has_line() {
  case $'\n'"$1"$'\n' in
    *$'\n'"$2"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

# The guard needs the full history. On a shallow clone the ancestry is not reliable, so
# the guard refuses. It does not pass on incomplete data.
if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
  fail "the repository is a shallow clone. The guard cannot read the history. Check out with fetch-depth: 0."
fi

git fetch --quiet "$REMOTE" "+refs/heads/*:refs/remotes/${REMOTE}/*" 2>/dev/null || true

# ---------------------------------------------------------------------------
# T-3 and T-2 — the tag itself
# ---------------------------------------------------------------------------
# These two checks run when the argument names a tag. The release workflow gives the
# tag name. A person can also give a bare commit for a local check, and then the guard
# reads the commit only.

if git rev-parse --verify --quiet "refs/tags/${COMMIT}" >/dev/null 2>&1; then
  TAG="$COMMIT"

  # Fetch the tag object from the remote and overwrite the local ref.
  #
  # actions/checkout does not fetch the tag object. It resolves the ref to a commit and
  # writes `+<commit-sha>:refs/tags/<tag>`, so the local ref is a lightweight ref and the
  # annotation is not there. Without this fetch, the T-2 check reads "lightweight" for
  # each tag in CI, and it refuses every release. The remote holds the true object.
  git fetch --quiet --force "$REMOTE" "+refs/tags/${TAG}:refs/tags/${TAG}" 2>/dev/null || true

  echo "  tag            : $TAG ($(git cat-file -t "refs/tags/$TAG" 2>/dev/null || echo unknown))"

  if ! [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "" >&2
    echo "  The tag name does not have the form vMAJOR.MINOR.PATCH." >&2
    echo "  Rule T-3 gives the form. The deploy workflow starts on 'v*' and on nothing else." >&2
    fail "the tag name '$TAG' is not vMAJOR.MINOR.PATCH (rule T-3)"
  fi

  # T-2 reports. It does not refuse.
  #
  # The Releases page on GitHub makes a lightweight tag, and it has no setting for an
  # annotated tag. A refusal here blocks each release that starts on that page, and a
  # guard that blocks the normal path is a guard that a person bypasses. The record of the
  # person and the time then comes from the GitHub release object, not from the git object.
  #
  # The source checks below are the control. They refuse a tag that is not on the release
  # line, and the form of the tag object does not change that.
  if [ "$(git cat-file -t "refs/tags/$TAG" 2>/dev/null || echo unknown)" != "tag" ]; then
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
      echo "::warning::The tag '$TAG' is lightweight. Rule T-2 asks for an annotated tag. Use 'git tag -a'."
    fi
    printf '  \033[33m! warning\033[0m       : the tag is lightweight, not annotated (rule T-2).\n'
    echo "                   An annotated tag records the person who cut it, and the time,"
    echo "                   in the git object. Use 'git tag -a' to record it there."
  fi
else
  echo "  note           : '$COMMIT' is not a tag here, so the T-2 and T-3 checks did not run."
fi

if ! TARGET=$(git rev-parse --verify --quiet "${COMMIT}^{commit}"); then
  fail "'$COMMIT' is not a commit."
fi

echo "  candidate      : $COMMIT ($(git rev-parse --short "$TARGET"))"
echo "  release branch : $RELEASE_BRANCH"

if ! RELEASE_TIP=$(git rev-parse --verify --quiet "$REMOTE/$RELEASE_BRANCH"); then
  if ! RELEASE_TIP=$(git rev-parse --verify --quiet "$RELEASE_BRANCH"); then
    fail "the release branch '$RELEASE_BRANCH' is not local and is not on '$REMOTE'."
  fi
fi

echo "  branch tip     : $(git rev-parse --short "$RELEASE_TIP")"

# ---------------------------------------------------------------------------
# Gate 2 — ancestry
# ---------------------------------------------------------------------------
# A commit is an ancestor of itself, so a tag on the branch tip passes.

if ! git merge-base --is-ancestor "$TARGET" "$RELEASE_TIP"; then
  echo "" >&2
  echo "  Gate 2 failed. The '$RELEASE_BRANCH' tip does not contain this commit." >&2
  AHEAD=$(git rev-list --count "$RELEASE_TIP..$TARGET" 2>/dev/null || echo "?")
  echo "  Commits here that '$RELEASE_BRANCH' does not have: $AHEAD" >&2
  SOURCES=$(
    git branch -r --contains "$TARGET" --format='%(refname:strip=3)' 2>/dev/null \
      | grep -v '^HEAD$' | sort -u
  ) || true
  if [ -n "$SOURCES" ]; then
    echo "  Branches that hold it:" >&2
    printf '%s\n' "$SOURCES" | sed 's|^|    |' >&2
  fi
  echo "" >&2
  echo "  Merge the work into '$RELEASE_BRANCH', then tag the merge commit." >&2
  echo "  A moved tag also gives this result. Cut a new tag. Do not move a tag." >&2
  fail "the commit is not contained in '$RELEASE_BRANCH'"
fi

# ---------------------------------------------------------------------------
# Gate 3 — the release line
# ---------------------------------------------------------------------------
# The first-parent line of the release branch is the line of the branch itself. Each
# merge adds one commit to that line. The tip of the branch that a person merged is the
# second parent, so it is not on the line, and its content is the content of that
# branch. Gate 3 refuses it, and it names the merge commit to tag in its place.

RELEASE_LINE=$(git rev-list --first-parent "$RELEASE_TIP")

if ! has_line "$RELEASE_LINE" "$TARGET"; then
  echo "" >&2
  echo "  Gate 3 failed. The commit is not on the line of '$RELEASE_BRANCH'." >&2
  echo "  '$RELEASE_BRANCH' contains the commit, but a merge put it there. The commit is" >&2
  echo "  a merged parent, and its content is the content of the branch that you merged." >&2

  MERGE_COMMIT=$(git rev-list --first-parent --ancestry-path "$TARGET..$RELEASE_TIP" 2>/dev/null | tail -1)
  if [ -n "$MERGE_COMMIT" ]; then
    echo "" >&2
    echo "  This merge commit put the work on '$RELEASE_BRANCH':" >&2
    echo "    $(git log -1 --format='%h %s' "$MERGE_COMMIT")" >&2
    echo "" >&2
    echo "  Tag that commit. Cut each tag from a fresh checkout:" >&2
    echo "    git checkout $RELEASE_BRANCH && git pull" >&2
  fi
  fail "the commit is not on the release line of '$RELEASE_BRANCH'"
fi

ok "$(git rev-parse --short "$TARGET") is on the release line of '$RELEASE_BRANCH'"
