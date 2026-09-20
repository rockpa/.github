# CI/CD fleet standard

The shared shape every RPA repo's GitHub Actions setup follows, and the guardrail
that keeps it from silently breaking. Read this before changing any workflow.

## Why this exists

The fleet is ~9 repos, each carrying its own workflow files, pinned to action SHAs,
with Dependabot opening bump PRs, merged through a `main` ↔ working-branch flow. For
a long time nothing validated the *result* of a bump/merge, so a malformed workflow
(a duplicate `uses:`, a bad merge) could ship and only surface at run time as
GitHub's "Invalid workflow file". The **actionlint gate** below closes that hole.

## The golden workflow set

| file | purpose | trigger |
|---|---|---|
| `actionlint.yml` | validate all workflow YAML (**required check**) | every `pull_request` |
| `ci.yml` | tests + SonarQube scan | push/PR to `main` |
| `deploy.yml` | deploy (per-target: self-hosted VNet, or Azure OIDC, or SWA) | push to `main` |
| `weekly-docs.yml` | thin caller of the `rockpa/.github` reusable docs refresh | weekly `schedule` |
| `pr-autofill.yml` | fill the PR body's "What Changed" from commits | PR `opened`/`synchronize`/`reopened` |

Not every repo has every file (a docs-only or manifest repo may have a subset), but
where a file exists it follows the shape here.

## The actionlint gate (the guardrail)

`actionlint.yml` runs on **every** pull request with **no `paths:` filter** — on
purpose. A required check that only ran when `.github/workflows/**` changed would
never report on other PRs, and a required-but-absent check blocks the PR forever.
Linting the whole workflow dir is a few seconds.

- Canonical copy: `rockpa/.github/.github/workflows/actionlint.yml`, also published as
  the org workflow-template (`workflow-templates/actionlint.yml`). Every repo carries
  its **own** copy — the gate is deliberately NOT a shared reusable, so it has no
  fleet-wide single point of failure.
- Keep the job id `actionlint` in every copy so the required-check **context is
  identical** across repos.
- actionlint is installed with `go install …@<pinned tag>` (no `curl | bash`, no
  third-party action whose inputs can churn). Bump the version in the canonical copy
  and let it propagate by hand; a bump is a normal reviewed PR.

### Making it a required check (do this once per repo, after the file's first run)

GitHub only lets you require a check context it has already seen, so the order is:
1. Merge `actionlint.yml` into the repo.
2. Let it run once on any PR.
3. Add `actionlint` to `main`'s required status checks (keep the existing
   `SonarQube` and `Analyze (<lang>)` CodeQL context; keep `strict: true`):

   `gh api -X PATCH repos/rockpa/<repo>/branches/main/protection/required_status_checks -f 'checks[][context]=actionlint'`
   (or add it in Settings → Branches → branch protection).

Required contexts per repo: `SonarQube`, `Analyze (python)` **or** `Analyze (javascript)`
(varies by language), and `actionlint`.

## Dependabot

- **`github-actions`, grouped, weekly, every repo.** Minor+patch bumps arrive as ONE
  weekly PR (kills the merge-storm that used to misalign merges); MAJOR bumps come as
  their own PRs so a breaking change stays visible. The actionlint gate validates
  whatever Dependabot proposes before it can merge.
- **`npm`, grouped, on the two SWA repos** — updates the committed `package-lock.json`.
- **Python is NOT on Dependabot.** Python deps go through `pip-compile`
  (`requirements.in` → hash-pinned `requirements.txt`) and are watched for CVEs by
  Aikido; Dependabot's pip updater does not cleanly regenerate a compiled/hashed lock.
  Security bumps are a manual `pip-compile --upgrade` reviewed PR.

## Action pinning discipline

Pin every `uses:` to a full 40-char SHA with an **accurate** `# vX.Y.Z` comment. Do
not float tags (`@v4`). Dependabot moves the SHA and its comment together, so once a
pin is correct it stays correct. If you pin by hand, verify the tag:
`git ls-remote --tags https://github.com/<owner>/<action> | grep <sha>`.

## The weekly-docs reusable (rename migration note)

The reusable lives at `rockpa/.github/.github/workflows/weekly-docs.yml` (renamed from
`nightly-docs.yml` — it has run weekly for a while). Callers pin it by SHA:

```yaml
uses: rockpa/.github/.github/workflows/weekly-docs.yml@<sha>  # bump via Dependabot
```

**Coordinated step after this rename merges:** existing callers still pin
`nightly-docs.yml@1f8a1f92…`, which keeps working (that old commit still has the old
filename). When `rockpa/.github` is merged with the rename, bump each caller in one PR:
change the path segment `nightly-docs.yml` → `weekly-docs.yml` **and** the SHA to the
new `rockpa/.github` commit together, and rename the caller file to `weekly-docs.yml`.
Dependabot will offer the SHA bump; the path segment is a hand-edit in that same PR.

## pr-autofill

Runs on `opened`, `synchronize`, and `reopened`, so the "What Changed" summary keeps up
with commits pushed after the PR opens (it used to run once, on open only). It fills
only while the PR template's marker line is still present, so re-runs never clobber a
hand-written summary. The marker string in the PR template and the one `pr-autofill.yml`
greps for **must match exactly** — if you change one, change both.

## ci.yml comes in two variants (by design)

- **guarded / incoming**: probes for `requirements*.txt`, skips tests when none exist,
  gates the Sonar step on `SONAR_TOKEN` being set (CI stays green before the token is
  configured). Used by newer/thin repos.
- **established**: hard-requires `requirements-dev.txt` and runs tests unconditionally.

Both are valid; pick the one that matches the repo's maturity.
