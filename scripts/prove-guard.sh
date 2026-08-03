#!/usr/bin/env bash
#
# prove-guard.sh — shows the tag guard at work. GitHub is not necessary.
#
# The script builds a scratch repository with `main` and `dev`, then it runs the guard
# against eight tags. Five tags pass and three are refused.
#
# Case 2 is the regression test for the removal of gate 1. Gate 1 read the set of
# branches that hold the commit, and it demanded `main` alone. An unrelated `feature/x`
# off `main` put a second name in that set, and the guard then refused the tag on the
# tip of `main`. Case 2 must stay PERMITTED.
#
# Case 8 is the CI condition. actions/checkout writes `+<commit-sha>:refs/tags/<tag>`, so
# the local ref of an annotated tag holds no annotation, and a check on the object type
# alone refuses each release. The guard fetches the tag object from the remote first.
#
# Case 4 is the 14 July 2026 condition: a build from `dev` offered for a production
# release. Case 5 is the 3 August 2026 condition: a tag on the tip of `dev` after the
# merge into `main`.
#
# Run:  scripts/prove-guard.sh

set -uo pipefail

GUARD="$(cd "$(dirname "$0")" && pwd)/verify-tag-source.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

rule() { printf '\n\033[2m%s\033[0m\n' "────────────────────────────────────────────────────────────"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

step "Set up a scratch repository"
mkdir -p "$WORK/origin" "$WORK/clone"
git init --quiet --bare "$WORK/origin"
cd "$WORK/clone"
git init --quiet -b main .
git config user.email demo@example.com
git config user.name "Release Guard Demo"
git remote add origin "$WORK/origin"

echo "v1" > app.txt
git add app.txt && git commit --quiet -m "release 1.0 content"
git push --quiet -u origin main

git checkout --quiet -b dev
echo "work in progress. The counterpart change is not merged." > feature.txt
git add feature.txt && git commit --quiet -m "dynamic switch — the switch-service change is not merged"
git push --quiet -u origin dev

# main gets the work through a merge commit. That commit is on the line of main, and it
# is the commit to release.
git checkout --quiet main
git merge --quiet --no-ff dev -m "promote dev to main"
git push --quiet origin main
MERGE_ON_MAIN=$(git rev-parse main)
FIRST_ON_MAIN=$(git rev-parse main~1)
DEV_TIP=$(git rev-parse dev)

echo "  main  = $(git rev-parse --short main)  (the merge commit)"
echo "  main~1= $(git rev-parse --short "$FIRST_ON_MAIN")  (an older commit on the line of main)"
echo "  dev   = $(git rev-parse --short "$DEV_TIP")  (the merged tip of dev)"

rule
step "CASE 1 — an annotated vX.Y.Z tag on the merge commit on main  (expected: PERMITTED)"
git tag -a v1.1.0 -m "release 1.1.0" "$MERGE_ON_MAIN"
if bash "$GUARD" v1.1.0 main; then CASE1=pass; else CASE1=fail; fi

rule
step "CASE 2 — the same tag, and an unrelated feature/x also holds the commit  (expected: PERMITTED)"
echo "  This case is the regression test for the removal of gate 1."
git branch --quiet feature/x main
git push --quiet -u origin feature/x
git tag -a v1.1.1 -m "release 1.1.1" "$MERGE_ON_MAIN"
if bash "$GUARD" v1.1.1 main; then CASE2=pass; else CASE2=fail; fi

rule
step "CASE 3 — a tag on an older commit on the line of main  (expected: PERMITTED)"
echo "  A release of an earlier version stays possible."
git tag -a v1.0.0 -m "release 1.0.0" "$FIRST_ON_MAIN"
if bash "$GUARD" v1.0.0 main; then CASE3=pass; else CASE3=fail; fi

rule
step "CASE 4 — a tag on the tip of dev that main does not have  (expected: BLOCKED)"
echo "  This is the 14 July condition. Gate 2 refuses it."
git checkout --quiet dev
echo "more work in progress" > feature2.txt
git add feature2.txt && git commit --quiet -m "work that main does not have"
git push --quiet origin dev
git tag -a v1.2.0 -m "release from dev"
if bash "$GUARD" v1.2.0 main; then CASE4=fail; else CASE4=pass; fi

rule
step "CASE 5 — a tag on the tip of dev, after the merge into main  (expected: BLOCKED)"
echo "  main contains this commit, so gate 2 passes. Gate 3 refuses it, because a merge"
echo "  put it there. It is a second parent, and its content is the content of dev."
git tag -a v1.3.0 -m "release from the merged dev tip" "$DEV_TIP"
if bash "$GUARD" v1.3.0 main; then CASE5=fail; else CASE5=pass; fi

rule
step "CASE 6 — a lightweight tag on the merge commit on main  (expected: PERMITTED, with a warning)"
echo "  T-2 reports and does not refuse. The Releases page on GitHub makes a lightweight"
echo "  tag, so a refusal here would block each release that starts on that page."
git tag v1.4.0 "$MERGE_ON_MAIN"
if bash "$GUARD" v1.4.0 main; then CASE6=pass; else CASE6=fail; fi

rule
step "CASE 7 — a tag name that is not vMAJOR.MINOR.PATCH  (expected: BLOCKED, rule T-3)"
git tag -a release-1 -m "release one" "$MERGE_ON_MAIN"
if bash "$GUARD" release-1 main; then CASE7=fail; else CASE7=pass; fi

rule
step "CASE 8 — an annotated tag that the checkout flattened to a lightweight ref  (expected: PERMITTED)"
echo "  actions/checkout writes '+<commit-sha>:refs/tags/<tag>', so the local ref holds no"
echo "  annotation. The guard fetches the tag object from the remote before it reads T-2."
git tag -a v1.5.0 -m "release 1.5.0" "$MERGE_ON_MAIN"
git push --quiet origin refs/tags/v1.5.0
git tag -d v1.5.0 >/dev/null
git tag v1.5.0 "$MERGE_ON_MAIN"        # the flat ref that a checkout leaves behind
echo "  local object type before the guard runs: $(git cat-file -t refs/tags/v1.5.0)"
if bash "$GUARD" v1.5.0 main; then CASE8=pass; else CASE8=fail; fi

rule
printf '\n\033[1mRESULTS\033[0m\n'
printf '  %-56s %s\n' "1. the annotated tag on the merge commit is permitted"  "$CASE1"
printf '  %-56s %s\n' "2. the same tag with an unrelated feature/x is permitted" "$CASE2"
printf '  %-56s %s\n' "3. the tag on an older commit on the line is permitted" "$CASE3"
printf '  %-56s %s\n' "4. the tag on the unmerged dev tip is blocked"         "$CASE4"
printf '  %-56s %s\n' "5. the tag on the merged dev tip is blocked"           "$CASE5"
printf '  %-56s %s\n' "6. the lightweight tag is permitted, with a warning"   "$CASE6"
printf '  %-56s %s\n' "7. the malformed tag name is blocked"                  "$CASE7"
printf '  %-56s %s\n' "8. the flattened annotated tag is permitted"           "$CASE8"

if [ "$CASE1$CASE2$CASE3$CASE4$CASE5$CASE6$CASE7$CASE8" = "passpasspasspasspasspasspasspass" ]; then
  printf '\n\033[32mAll eight cases give the specified result.\033[0m\n\n'; exit 0
fi
printf '\n\033[31mOne case or more does not give the specified result.\033[0m\n\n'; exit 1
