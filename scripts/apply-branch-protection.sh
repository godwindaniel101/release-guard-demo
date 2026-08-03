#!/usr/bin/env bash
#
# apply-branch-protection.sh — makes the guards block, not report.
#
# The workflow reports the result. Branch protection removes the merge button. Without
# this script, a person can merge a pull request that failed the check.
#
# The script applies the settings, then it reads them back. The read-back confirms that
# the merge button is unavailable when the PR source guard fails.
#
# The GitHub CLI is necessary, and you must be logged in.
#
# NOTE: on the GitHub Free plan, you can protect a branch on a PUBLIC repository only.
# If you get a 403 on a private repository, make the repository public or use a paid plan.

set -euo pipefail

# This text must be the same as the `name:` of the job in pr-source-guard.yml.
CHECK="main promotion source"
REPO="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"

echo "Apply branch protection to $REPO:main"

gh api -X PUT "repos/$REPO/branches/main/protection" \
  -H "Accept: application/vnd.github+json" \
  --input - <<JSON
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["$CHECK"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "required_approving_review_count": 0
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": false
}
JSON

echo ""
echo "Applied to the branch:"
echo "  • a pull request is necessary before a merge"
echo "  • the check '$CHECK' must pass"
echo "  • the branch must be up to date before a merge"
echo "  • an administrator cannot bypass the settings"
echo "  • a force push and a branch deletion are blocked"

# Rule T-4 — a tag is permanent. A tag ruleset blocks a force update on a tag with the
# form `v*`, so a person cannot move a released tag. Without this rule, T-4 is a written
# rule with nothing behind it.
#
# The rule blocks a force update only. It does not block a deletion, because rule T-5
# needs the `revoke` job in release.yml to delete an invalid tag. A deletion rule here
# would stop that job, and an invalid release would stay published.
#
# The older endpoint `repos/{repo}/tags/protection` gives 404 now. GitHub replaced tag
# protection with rulesets.
RULESET_NAME="release tags are permanent (T-4)"
echo ""
echo "Apply the tag ruleset for 'v*' (rule T-4):"

EXISTING=$(gh api "repos/$REPO/rulesets" --jq ".[] | select(.name==\"$RULESET_NAME\") | .id" 2>/dev/null) || EXISTING=""

if [ -n "$EXISTING" ]; then
  echo "  • the ruleset is already there (id $EXISTING). A tag with the form 'v*' cannot move."
elif gh api -X POST "repos/$REPO/rulesets" --input - >/dev/null 2>&1 <<JSON
{
  "name": "$RULESET_NAME",
  "target": "tag",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/tags/v*"], "exclude": [] } },
  "rules": [ { "type": "non_fast_forward" } ]
}
JSON
then
  echo "  • a tag with the form 'v*' cannot move"
else
  echo "  ! the rulesets endpoint refused the call." >&2
  echo "    A ruleset needs a public repository on the Free plan. Add the rule by hand:" >&2
  echo "    Settings → Rules → Rulesets → New tag ruleset → target 'refs/tags/v*'" >&2
  echo "    → Block force pushes. Do not add a deletion rule: rule T-5 deletes an" >&2
  echo "    invalid tag, and a deletion rule stops that job." >&2
  echo "    Rule T-4 is not enforced until you do this." >&2
fi

echo ""
echo "Read the settings back:"

PROTECTION=$(gh api "repos/$REPO/branches/main/protection")
ADMINS=$(printf '%s' "$PROTECTION" | jq -r '.enforce_admins.enabled')
CONTEXTS=$(printf '%s' "$PROTECTION" | jq -r '.required_status_checks.contexts[]?')

printf '  administrators cannot bypass : %s\n' "$ADMINS"
printf '  required checks              : %s\n' "$(printf '%s' "$CONTEXTS" | paste -sd, -)"

# The test uses no pipe. A pipe into `grep -q` with `set -o pipefail` can report a
# failure when `grep` exits at the first match and the writer gets a SIGPIPE.
case $'\n'"$CONTEXTS"$'\n' in *$'\n'"$CHECK"$'\n'*) FOUND=yes ;; *) FOUND=no ;; esac

if [ "$FOUND" = "yes" ] && [ "$ADMINS" = "true" ]; then
  echo ""
  echo "✓ The merge button is unavailable when the PR source guard fails."
  exit 0
fi

echo ""
echo "✗ The guard is advisory. The merge button stays available." >&2
echo "  The check '$CHECK' is not required, or an administrator can bypass it." >&2
exit 1
