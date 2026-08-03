# Branch and Release Standard

**Status:** Draft · **Applies to:** each service that a tag deploys to production

Each release process has an operator. A release process that depends on the vigilance of that
operator is not safe. One day, a person who does not see the default value operates it. A check
applies each rule in this standard, and each check fails on its own. No rule in this standard
depends on memory.

---

## 1. Branches

| Branch | Purpose | Receives from | Deploys to |
|---|---|---|---|
| `main` | The release branch. Each production artifact starts here. | `dev`, or `hotfix/*` | production, by a tag only |
| `dev` | The integration branch. You combine and verify work here. | `feature/*`, `fix/*` | a non-production environment |
| `feature/*`, `fix/*` | One unit of work | — | a temporary preview only |
| `hotfix/*` | An urgent production fix that cannot wait for the normal path | `main` | production, by a tag, then a merge back into `dev` |

You can always release `main`. You cannot always release `dev`. Do not use `dev` as if you can.

## 2. The promotion path

```
feature/*  ──PR──▶  dev  ──PR──▶  main  ──tag──▶  production
                                    ▲
                     hotfix/*  ──PR─┘   (a merge back into dev is necessary)
```

Work moves in one direction. There is no path from a feature branch to `main`. There is no path
to production that does not go through `main`.

**Rule P-1.** `main` accepts a pull request from `dev` and from `hotfix/*` only.
`.github/workflows/pr-source-guard.yml` applies this rule on each pull request event. The check
compares the name of the source branch. Branch protection makes the merge button unavailable
when the check fails. See section 6.

**Rule P-2.** After you release a hotfix from `hotfix/*`, merge the work back into `dev`. Do
this before the next promotion. If you do not, the next merge from `dev` into `main` removes
the fix.

**Rule P-3.** Each commit on `main` arrives by a merge from `dev` or from `hotfix/*`. A direct
push, and a merge that an administrator forces, do not start the check for rule P-1. Therefore
`.github/workflows/main-integrity.yml` checks the source of the work on each push to `main`.
That check finds the condition. It cannot prevent it. It fails the branch and opens an issue.
Section 6 gives the settings that prevent it.

## 3. Tags

**Rule T-1.** Cut a release tag on the `main` branch only. The guard makes one check and one
warning on the tag, then two gates on the commit. Each check and each gate must pass. `scripts/verify-tag-source.sh` holds
them, and the `guard` job in `.github/workflows/release.yml` runs the script with the tag name.

- **Gate 2, the ancestry.** The tip of `main` must contain the tagged commit. This gate also
  gives the diagnostics on a refusal: it reports how many commits the tagged commit holds that
  `main` does not hold, and it names each branch that holds the commit.
- **Gate 3, the release line.** The commit must be on the first-parent line of `main`. That
  line is the line of `main` itself. This gate makes the decision. A tag on an older commit on
  that line passes, so a release of an earlier version stays possible.

If one check or one gate fails, the guard refuses the tag, and no deployment runs.

*Note: cut each tag from a fresh checkout of `main`. A tag on the tip of a branch that you
merged a moment ago is a second parent, not a commit on the line of `main`, and gate 3 refuses
it. The guard names the merge commit to tag in its place.*

```bash
git checkout main && git pull
```

*Note: there is no gate 1. An earlier gate 1 read the set of branches that hold the commit, and
it demanded the name `main` alone. That set is not a property of the release. It grows when a
person cuts a branch off `main`, and it does not shrink until that branch is deleted. The same
commit, with the same tag, still the tip of `main`, gave a pass before a colleague cut
`feature/x` and a refusal after. A gate that refuses a correct release is a gate that a person
bypasses in an incident, and that outcome is worse than the outcome that the gate stops. Case 2
in `scripts/prove-guard.sh` holds that condition, so the gate cannot come back unseen.*

**Rule T-2.** Cut an annotated tag when you can. Use `git tag -a`. An annotated tag records
the person who cut it, and the time, in the git object, so each clone holds that record and an
audit needs no API. A lightweight tag records neither.

**T-2 reports. It does not block.** The Releases page on GitHub makes a lightweight tag, and it
has no setting for an annotated tag. A refusal would block each release that starts on that
page, and a guard that blocks the normal path is a guard that a person bypasses. The guard
prints a warning, and the release continues. For a lightweight tag, the record of the person and
the time comes from the GitHub release object.

The guard reads the tag object from the remote, not from the local ref. `actions/checkout` does
not fetch a tag object: it resolves the ref to a commit and writes `+<commit-sha>:refs/tags/<tag>`,
so the local ref of an annotated tag holds no annotation. Case 8 of the harness holds this
condition.

**Rule T-3.** Give a tag the form `vMAJOR.MINOR.PATCH`. A tag with the form `v*` starts the
deploy workflow. No other tag starts it. The guard reads the tag name, and it refuses each name
that does not have this form.

**Rule T-4.** A tag is permanent. To replace a bad release, cut a new tag. Do not move a tag. A
tag that moves makes the deployment history unclear, and it breaks each audit of that history. A
tag ruleset on `refs/tags/v*` applies this rule, and `scripts/apply-branch-protection.sh` adds
it. Section 6 gives the setting. Without that setting, this rule is a written rule with nothing
behind it.

The ruleset blocks a force update on a tag. It does not block a deletion, because rule T-5 needs
the `revoke` job to delete an invalid tag.

**Rule T-5.** The workflow revokes an invalid tag. It does not only report it. GitHub creates
the tag and the release object before a workflow runs. Therefore a failed check leaves an
invalid release in place. The `revoke` job deletes both objects, and it opens an issue. A red
check that leaves the artifact in place is a message, not a control.

The issue names the check that refused the tag. The guard writes its reason to the step output,
and the `revoke` job reads it. An issue that gives one generic reason for each cause teaches a
person to stop reading it.

### Style, not a rule

Move `main` forward with a merge commit, because the first-parent line of `main` then reads as
one release per line, and a person can read the release history with
`git log --first-parent main`. A fast-forward merge is not a fault, and the guard permits a tag
on a fast-forwarded `main`: the content of that commit is the content of `main`.


### Cut a release

```bash
git checkout main && git pull
git tag -a v1.4.0 -m "release 1.4.0"
git push origin v1.4.0
```

### Correct a tag that you pushed on the wrong branch

The guard stops the deployment, so nothing went to production. Delete the tag, then cut it
again on `main`:

```bash
git push --delete origin v1.4.0
git tag -d v1.4.0
```

## 4. Deployment

**Rule D-1.** A tag push starts a production deployment. Nothing else starts it. The production
deploy path has no branch selection, and therefore it has no default value for an operator to
leave.

**Rule D-2.** The guard is a separate job, and the deploy job depends on it. The guard is not a
step inside the deploy job. A person can edit a job to stop the checks on its own conditions. A
person cannot bypass a dependency without a change to the workflow graph.

**Rule D-3.** The deploy job runs the guard again. This is cheap, and it closes the time
between the result of the guard job and the start of the deployment.

**Rule D-4.** Check out with `fetch-depth: 0`. On a shallow clone, Git cannot list the branches
that hold a commit, and the ancestry is not reliable. The guard refuses a shallow clone. It
does not pass on incomplete history.

**Rule D-5.** A release is not complete when the deployment is successful. A release is
complete when a money-path outcome check passes. A healthy pod and inbound traffic show that
the service is alive. They do not show that the service is correct. A service can be fully
healthy while each transaction fails. `scripts/post-deploy-check.sh` is a necessary step, and
it applies this rule.

**Rule D-6.** Rule D-5 applies to each class of release. An observability release, a
configuration release and a documentation release use the same gates as a feature release. A
person gives an exemption for the *intended* contents of a change. The artifact holds the
actual contents.

**Rule D-7.** One workflow starts on a tag. The guard, revoke and deploy jobs are in that
workflow. Two workflows on one trigger give two runs, and two sets of results, for one release.
Then the person who reads the results cannot tell which run controls the deployment.

## 5. Environment parity

**Rule E-1.** A non-production environment deploys the ref that production will run, with the
change under test on top. An environment that runs a different branch does not verify the
artifact that goes to production.

**Rule E-2.** `dev` is not a deploy source for an environment that stands in for production.

## 6. Necessary branch protection

**The workflow reports the result. Branch protection is the control that blocks.** Until you
apply the settings below, a person can merge past a failed check. Also, a direct push to `main`
does not start the pull request guard. This is the most common reason for a correct guard that
guards nothing.

Apply the settings with one command:

```bash
scripts/apply-branch-protection.sh
```

The script applies the settings, then it reads them back. The read-back confirms that the merge
button is unavailable when the PR source guard fails. The script fails if the check is not a
required check, or if an administrator can bypass it.

To apply the settings by hand, on `main`:

- A pull request is necessary before a merge
- The check **`main promotion source`** must pass
- A branch must be up to date before a merge
- An administrator cannot bypass the settings above

And on the tags, for rule T-4:

- A tag with the form `v*` cannot move. Use a tag ruleset on `refs/tags/v*` with the rule "block
  force pushes". The older tag protection endpoint gives 404 now, because GitHub replaced it with
  rulesets.
- Do not add a deletion rule to that ruleset. Rule T-5 needs the `revoke` job to delete an
  invalid tag. A deletion rule stops that job, and an invalid release then stays published.

Under **Settings → Environments → production**, make a review necessary. Also limit the deploy
branch rule to a tag with the form `v*`.

**The name of the check.** The text `main promotion source` is the `name:` of the job in
`pr-source-guard.yml`. Branch protection holds the same text. If you change one text and not
the other text, the check stays pending, and each merge into `main` stops.

**To rename the check.** Two names cannot both be required at one time. A required check that no
job reports stays pending, so a list of the old name and the new name blocks each pull request:
one of the two names is always absent. Use this order:

1. Change the job name in `pr-source-guard.yml` on a branch, and merge it into `dev`.
2. Open the promotion pull request from `dev` into `main`. Do not merge it yet.
3. Change the required check to the new name:
   `gh api -X PATCH repos/:owner/:repo/branches/main/protection/required_status_checks -f 'contexts[]=<new name>'`
4. The promotion pull request reports the new name, because a pull request runs the workflow from
   its own branch. Merge it.

Between step 3 and step 4, a pull request from a branch that holds the old job name stays
blocked. That is the safe direction.

**Availability.** On the GitHub Free plan, you can protect a branch, and use a ruleset, on a
**public** repository only. On a private repository with a free plan, the settings are not
available. Then the guards stay advisory, and the workflow files do not change this. Make the
repository public, or use a plan that includes protection for a private repository.

**Rule B-1.** A guard that is not a required status check is a suggestion. Confirm the setting
after you apply it:

```bash
gh api repos/:owner/:repo/branches/main/protection | jq '.enforce_admins.enabled, .required_status_checks.contexts'
```

## 7. The failure that each rule removes

| Rule | Failure that it removes |
|---|---|
| P-1 | Work that no person integrated reaches the release branch |
| P-2 | The next promotion removes a hotfix, and the production bug comes back |
| P-3 | Work reaches `main` outside the promotion path |
| T-1 | A build from a branch that is not the release branch reaches production |
| T-2 | A release has no record of the person who cut it, and no record of the time. This rule reports and does not block, so the record can come from the GitHub release object instead. |
| T-3 | A tag with an unexpected name starts a deployment, or starts nothing |
| T-4 | A person cannot reconstruct the deployment history |
| T-5 | An invalid release stays in place after a failed check |
| D-1 | An operator leaves a branch selection at its default value |
| D-2 | A person disables a guard with an edit to the job that it protects |
| D-3 | Work reaches `main` between the result of the guard and the start of the deployment |
| D-4 | A guard passes on incomplete history |
| D-5 | A person reports a successful release while each transaction fails |
| D-6 | A class of change gives itself an exemption from verification |
| D-7 | Two runs for one release, with no clear control |
| E-1 | An artifact reaches production, and no environment ran it |
| E-2 | An environment that stands in for production runs the content of `dev` |
| B-1 | A guard reports, but it does not block |

## 8. Confirm that the standard holds

```bash
scripts/prove-guard.sh
```

The script builds a scratch repository with `main` and `dev`, and it merges `dev` into `main`.
Then it confirms eight results:

| # | Case | Result | Applies |
|---|---|---|---|
| 1 | An annotated `vX.Y.Z` tag on the merge commit on `main` | permitted | — |
| 2 | The same tag, and an unrelated `feature/x` also holds the commit | permitted | the removal of gate 1 |
| 3 | A tag on an older commit on the first-parent line of `main` | permitted | gate 3 |
| 4 | A tag on the tip of `dev` that `main` does not have | refused | gate 2 |
| 5 | A tag on the tip of `dev`, after the merge into `main` | refused | gate 3 |
| 6 | A lightweight tag on the merge commit on `main` | permitted, with a warning | T-2 |
| 7 | A tag with the name `release-1` on the merge commit on `main` | refused | T-3 |
| 8 | An annotated tag that a checkout flattened to a lightweight ref | permitted | the CI behaviour of actions/checkout |

Case 2 is the case that must not regress. An earlier gate 1 refused it, and gate 1 therefore
refused most correct releases on a repository with several engineers.

`.github/workflows/guard-proof.yml` runs the script on each pull request and on each push to
`main` and to `dev`. A change to the guard cannot reach `main` with no case behind it.

**Rule B-2.** A test that runs when a person remembers it is not a control. The harness runs as
a check.
