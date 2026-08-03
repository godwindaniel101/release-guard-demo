# release-guard-demo

This repository shows three release guards at work.

1. **`main` accepts a pull request from `dev` and from `hotfix/*` only.** For each other
   source branch, a required check fails and the merge button is unavailable.
2. **A release tag must be on the `main` branch.** If the tag is on a different branch,
   the guard refuses the release, and no deployment runs.
3. **A tag starts a production deployment. A branch selection does not.** There is no
   default value for an operator to leave.

These guards are the R-1 and R-4 controls in the 14 July 2026 incident report. In that
incident, a build from `dev` went to production. The release workflow accepted each branch
that the operator selected. The guard in `scripts/verify-tag-source.sh` refuses that build.

## What the tag guard reads

The guard makes one check and one warning on the tag, then two gates on the commit.

| Check or gate | Question | It stops |
|---|---|---|
| T-3, the tag name | Does the name have the form `vX.Y.Z`? | A tag with the name `release-1` |
| T-2, the tag object | Is the tag annotated? | Nothing. This one **warns and does not block**, because the Releases page on GitHub can make a lightweight tag only. For such a tag, the record of the person and the time comes from the GitHub release object. |
| Gate 2, ancestry | Does the tip of `main` contain the commit? | A tag on work that `main` does not have. This gate also gives the diagnostics on a refusal. |
| Gate 3, release line | Is the commit on the first-parent line of `main`? | A tag on the tip of `dev`, before **and** after the merge into `main` |

**Gate 3 makes the decision.** The first-parent line of `main` is the line of `main` itself.
Each merge adds one commit to that line, and the tip of the branch that a person merged is the
second parent. So a tag on `dev` is refused before the merge, and it is refused after the merge.
The guard names the merge commit to tag in its place.

A tag on an older commit on the line of `main` passes. A release of an earlier version stays
possible.

### Why the guard reads the line, and not the branch names

A merge does not move the commit from `dev` to `main`. A merge **makes** a new commit on `main`
with two parents: the old tip of `main`, and the tip of `dev`. The content comes from `dev`. The
commit is new, and it sits on the line of `main`.

```
dev   A ── B ── C          C is the tip of dev. It is a second parent. Gate 3 refuses it.
             ╲
main  A ────── M           M is the merge commit. It is on the line of main. Gate 3 permits it.
```

The release path:

```bash
gh pr create --base main --head dev && gh pr merge --merge
git checkout main && git pull
git tag -a v1.4.0 -m "release 1.4.0" && git push origin v1.4.0
```

**An earlier gate 1 read branch names, and it was wrong.** That gate listed each branch that
holds the commit, and it demanded the name `main` alone. The set of branches that hold a commit
is not a property of the release. It grows when a person cuts a branch off `main`, and it does
not shrink until that branch is deleted:

```
tag the merge commit on main       -> holders: main             -> PERMIT
a colleague cuts feature/x off main -> holders: feature/x,main   -> REFUSE
```

The same commit, the same tag, still the tip of `main`. On a repository with several engineers,
another branch almost always holds the tip of `main`, so that gate refused most correct
releases. A gate that refuses a correct release is a gate that a person bypasses in an incident,
and that outcome is worse than the outcome that the gate stops. Case 2 in the harness holds this
condition, so the gate cannot come back unseen.

## Show the guard in 30 seconds. GitHub is not necessary.

```bash
scripts/prove-guard.sh
```

The script builds a scratch repository with `main` and `dev`, and it merges `dev` into `main`.
Then it runs the guard against eight tags.

| # | Case | Result | Applies |
|---|---|---|---|
| 1 | An annotated `vX.Y.Z` tag on the merge commit on `main` | **permitted** | — |
| 2 | The same tag, and an unrelated `feature/x` also holds the commit | **permitted** | the removal of gate 1 |
| 3 | A tag on an older commit on the line of `main` | **permitted** | gate 3 |
| 4 | A tag on the tip of `dev` that `main` does not have | blocked. This is the 14 July condition. | gate 2 |
| 5 | A tag on the tip of `dev`, after the merge into `main` | blocked | gate 3 |
| 6 | A lightweight tag on the merge commit on `main` | **permitted**, with a warning | T-2 |
| 7 | A tag with the name `release-1` | blocked | T-3 |
| 8 | An annotated tag that a checkout flattened to a lightweight ref | **permitted** | the CI behaviour of actions/checkout |

Case 2 is the case that must not regress.

This is the output for case 5, the tag on the merged tip of `dev`:

```
  tag            : v1.3.0
  candidate      : v1.3.0 (e7d44d0)
  release branch : main
  branch tip     : 0dd856d

  Gate 3 failed. The commit is not on the line of 'main'.
  'main' contains the commit, but a merge put it there. The commit is
  a merged parent, and its content is the content of the branch that you merged.

  This merge commit put the work on 'main':
    0dd856d promote dev to main

  Tag that commit. Cut each tag from a fresh checkout:
    git checkout main && git pull

✗ RELEASE BLOCKED — the commit is not on the release line of 'main'
```

## Show the guards on GitHub

```bash
gh repo create release-guard-demo --private --source=. --push
git push origin dev
scripts/apply-branch-protection.sh
```

The last command makes the check a required check, and it reads the setting back. Until you
run it, the check reports the result but the merge button stays available.

Then do each test.

**Guard 1 — the source branch of a pull request.** Push a branch, then open a pull request
into `main`:

```bash
git checkout -b feature/direct-to-main
echo x >> src/app.js && git commit -am "try a direct merge into main" && git push -u origin HEAD
gh pr create --base main --head feature/direct-to-main --title "this must fail" --body ""
```

The check fails and gives the correct path. The merge button is unavailable.

**Guard 3 — the tag source branch.** Cut a tag on `dev`, then push it:

```bash
git checkout dev
git tag -a v0.1.0-bad -m "release from dev"
git push origin v0.1.0-bad
```

The `guard` job fails, and the `deploy` job does not run. The `revoke` job deletes the tag and
the release, and it opens an issue. You do not clean up by hand. Confirm the result:

```bash
git fetch --prune --prune-tags && git tag -l 'v0.1.0-bad'   # expect no output
```

**The permitted path.** Merge `dev` into `main`, then cut the tag on `main`:

```bash
gh pr create --base main --head dev --title "promote dev" --body "" && gh pr merge --merge
git checkout main && git pull
git tag -a v0.1.0 -m "release 0.1.0" && git push origin v0.1.0
```

Both workflows pass, and the deployment runs.

## The files

```
.github/workflows/
  pr-source-guard.yml       Guard 1 — main accepts dev and hotfix/* only (pull requests)
                            The job name is the required check: "main promotion source"
  main-integrity.yml        Guard 2 — the source of the work, checked on each push to main
  release.yml               Guard 3, revoke and deploy. A tag starts this workflow only.
  guard-proof.yml           The eight cases of the harness, as a check on each pull request
scripts/
  verify-tag-source.sh      Two tag checks and two gates, with a message for the operator
  prove-guard.sh            The local proof. Eight cases. GitHub is not necessary.
  apply-branch-protection.sh  Makes the guards block, and reads the setting back
  deploy.sh                 A substitute for a deployment
  post-deploy-check.sh      A substitute for a money-path outcome check
docs/
  BRANCH_RELEASE_STANDARD.md  The standard that these guards apply
src/
  app.js                    A small payload to give a version to
```

## Design notes

**The name of the check is a contract.** Branch protection holds the text
`main promotion source` as the required status check. That text is the `name:` of the job in
`pr-source-guard.yml`. If you change one and not the other, the check stays pending, and each
merge into `main` stops. Two names cannot both be required during a rename, because a required
check that no job reports stays pending. Section 6 of the standard gives the order to use.

**The workflow revokes an invalid release. It does not only report it.** GitHub creates the
tag and the release object before a workflow runs. A failed check leaves an invalid release in
place. The `revoke` job deletes both objects. This is the difference between a check that
reports and a control that holds.

**One workflow for one trigger.** The guard, the revoke and the deploy jobs are in
`release.yml`. Two workflows on `push: tags` give two runs for one release. Then the person
who reads the result cannot tell which run controls the deployment.

**Deploy depends on the guard job.** `release.yml` declares `needs: guard`. A person can edit
a job to stop the checks on its own conditions. A person cannot bypass a dependency without a
change to the workflow graph, and that change is visible in the diff.

**The guard refuses a shallow clone.** Git cannot list the branches that hold a commit on a
shallow clone, and `git merge-base` is not reliable. The script reads
`is-shallow-repository` and refuses. A guard that becomes permissive in an unusual condition
is worse than no guard, because persons trust it.

**A test uses no pipe.** The gates do not send a list into `grep -q`. `grep -q` exits at the
first match. The process on the left of the pipe then writes to a closed pipe, and
`set -o pipefail` reads that SIGPIPE as a failure. The block then depends on the time that
each process takes. The `has_line` function in `verify-tag-source.sh` matches with a `case`
statement, and it gives the same result each time.

**The message is for the operator.** When the guard refuses, it names each branch that holds
the commit. It also gives the number of commits that `main` does not have. Then it gives the
commands that correct the tag. A person finds a way past a guard that gives only a refusal.

## The limits of this demo

The deploy script and the post-deploy check are substitutes. The demo shows the guards, not
the deployment. Branch protection and the environment rules are repository settings. You
cannot put them in the repository. `scripts/apply-branch-protection.sh` applies them, and
section 6 of the standard lists them. This repository does not touch a production system.
