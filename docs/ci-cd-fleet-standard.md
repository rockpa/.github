# CI/CD fleet standard

How every RPA repo runs the same checks on every pull request, which ones must pass
before code merges, and how to enable and enforce all of it without locking anyone out
or freezing the fleet. This is the reference; read it before changing any workflow or
the org rule set.

Written for: whoever maintains the fleet's CI/CD (today one person, growing to a small
team). Plain English on purpose.

---

## What we are trying to deliver

Four capabilities, the same in every repo, enforced where it matters:

1. **Three automated reviewers on every PR** — Aikido, CodeQL, and Sonar.
2. **A guardrail that the workflow files themselves are valid** — actionlint.
3. **Weekly self-updating docs** — a Claude agent that opens a docs PR.
4. **Commit messages pulled into the PR description** — pr-autofill.

## The principles that keep it stable

- **Each repo keeps its own workflow files, standardized by convention.** `actionlint.yml`
  and `pr-autofill.yml` are byte-identical fleet-wide (published as org templates in
  `rockpa/.github/workflow-templates/`); `ci.yml` and `deploy.yml` are per-repo (Python vs
  Node, self-hosted vs hosted) and share only conventions — the `CI` job name, SHA pins,
  the best-effort Sonar step. Those invariants are held by review, not a shared file, so
  watch for drift. We do NOT put CI or deploy logic in a central workflow that every repo calls. A central required
  workflow is a single point of failure — one bad push would red-gate every repo at once,
  and a reusable workflow also renames the required-check contexts. The only shared
  reusable is the weekly-docs agent (a scheduled job, never a required check).
- **Pin every action to a full commit SHA with a `# vX.Y.Z` comment; Dependabot bumps
  them.** Never pin a moving tag (`@v1`) — a floating tag is mutable and is a
  supply-chain downgrade from a SHA. GitHub is explicit that a SHA is the only immutable
  pin. This applies to the shared `weekly-docs` reusable too: its callers pin an
  **immutable SHA**, never `@main`. (A `@main` pin was tried and rejected — that job has
  `id-token: write` (OIDC), `contents`/`pull-requests: write`, and the org token, so a
  mutable ref turns any push to `rockpa/.github` into RCE in a privileged context; both
  Aikido and the harness flagged it.) To avoid hand-bumping the pin on every reusable
  change, **cut release tags on `rockpa/.github`** — Dependabot then bumps the caller pins
  automatically (it can't today only because that repo has no releases yet).
- **Never rename or delete a published shared workflow file.** The path is part of the
  reference (`owner/repo/path@ref`), so a rename breaks every caller and no pin protects
  against it. If a rename is ever unavoidable, add the new file, leave the old one in
  place delegating to it, and treat it as a coordinated migration — not a Dependabot bump.
- **Enforce required checks with ONE org-level rule set, not per-repo settings.** One
  place to manage; it scales with the team. Requires the GitHub Team plan (org rule sets
  are not available on Free for private repos).
- **Nothing external that we don't operate becomes a merge blocker without a break-glass
  path.** A required reviewer (Sonar/Aikido/CodeQL) having an outage or an expired token
  must be an annoyance, not a fleet-wide freeze.

---

## Capability 1 — Aikido, CodeQL, Sonar on every PR

These are three different mechanisms, so they are wired and required differently:

- **Sonar** is split into two required checks so each means exactly one thing:
  - **`CI`** — every repo's CI job is named `CI` and reports the `CI` check. It runs the
    tests. Its Sonar scan step is `continue-on-error: true` (best-effort submit), so a red
    `CI` means **tests failed** — never a Sonar gate failure.
  - **`SonarCloud Code Analysis`** — the check SonarCloud's GitHub App posts on the PR
    (verified: this is the exact context name on datagate's live PRs today). It reflects the
    **quality gate** and is byte-identical across repos. Require this for Sonar's verdict.
  So require both `CI` (tests) and `SonarCloud Code Analysis` (Sonar gate). The
  `SonarCloud Code Analysis` check only appears on a repo once it is imported/bound as a
  SonarCloud project (see the enablement list) — require it per repo as each is bound.
- **CodeQL** runs through GitHub "default setup" (no workflow file). Its check context is
  **per language**: `Analyze (python)` on the Python repos, `Analyze (javascript-typescript)` on the
  two SWA repos. There is no single fleet-wide CodeQL context — require the right one per
  language (per-language rule-set targeting).
- **Aikido** runs through its GitHub App and posts two checks (verified from live PRs):
  **`Aikido Security: check code`** and **`Aikido Security: Deep Review`**. Require
  `Aikido Security: check code` (add Deep Review too if you want it blocking). Confirm the
  app is installed on every in-scope repo.

**Enablement:** all three reviewers (Sonar, CodeQL, Aikido) are enabled fleet-wide. There is
**one org-level `SONAR_TOKEN`** (org secret, scope ALL) — no per-repo token; each repo is
imported as its own SonarCloud project.

Do NOT infer enablement from whether a check appears on a given PR: CodeQL default setup and
Aikido don't post a check on every PR (a docs-only or no-code change won't trigger a scan),
and a repo with little/no analyzable code (e.g. `administrative`) can be fully enabled yet
produce no `Analyze (...)` check because there's nothing to analyze. The tools' own dashboards
are the source of truth for enablement.

Practical rule for the rule set: **require, per repo, only the checks that repo actually
produces on a PR.** A repo with no analyzable code won't emit `Analyze (...)` / Sonar, so
don't require those there — require `actionlint` (and `CI` where a CI job exists). Match the
required set to what each repo reports; don't require a check a repo never emits.

Sonar staging detail: the org `SONAR_TOKEN` is present on every repo, so the scan step runs
everywhere; its `continue-on-error: true` means a not-yet-imported repo's "project doesn't
exist" error can't red the `CI` (tests) check. Leave `continue-on-error` in place — the gate
is the separate `SonarCloud Code Analysis` required check, which simply doesn't appear until
the repo is imported. Add that check to a repo's required set once it reports.

Consequence to know: on a repo that isn't yet bound-and-required, `continue-on-error` means a
genuinely broken scan (bad project key, auth, quota) is swallowed and CI stays green with no
red anywhere. So Sonar is effectively advisory on a repo until it is both bound AND its
`SonarCloud Code Analysis` check is in the required set — close that gap per repo promptly.

---

## Capability 2 — the actionlint gate

`actionlint.yml` is a byte-identical per-repo workflow. It runs on **every** PR with **no
`paths:` filter** (a path-filtered required check would stay "pending" forever on PRs that
don't touch workflows and block them), and its job id is **`actionlint`** in every repo so
the required-check context is identical fleet-wide.

It installs actionlint as a **pinned, checksum-verified prebuilt binary** — it downloads
the exact release tarball and refuses to run unless its sha256 matches the pinned hash. No
`go install` (which depends on the Go proxy at merge time and isn't Dependabot-tracked) and
no `curl | bash` of a moving script. To bump: change `ACTIONLINT_VERSION` and
`ACTIONLINT_SHA256` together (the hash is in the release's `checksums.txt`).

The two repos whose deploy uses CUSTOM self-hosted runner labels
(`internal-apps-azure-functions-api` and `sponsored-projects-portal-azure-functions-api`,
`runs-on: [self-hosted, rpa-edw, azure-functions]`) carry a `.github/actionlint.yaml`
declaring those labels so actionlint doesn't flag them. datagate uses the built-in
`self-hosted` label only, which actionlint accepts with no config.

**Before making it required:** it has been run against every repo and is clean, but run it
once on each repo's default branch first (the rule set can only require a context it has
seen), then add `actionlint` to the required set.

---

## Capability 3 — weekly self-updating docs

A reusable workflow in `rockpa/.github/.github/workflows/weekly-docs.yml` runs a Claude
agent weekly that reads each repo's recent changes, edits the Markdown docs, and opens a
PR. Each repo has a thin caller pinned to it by SHA. (The reusable's activity gate and
changed-files window were widened from 24–48h to a full week to match the weekly schedule —
the nightly→weekly rename had left them at nightly windows, which would have made the agent
self-skip almost every week and, when it did run, see only ~2 of 7 days.)

**One thing to fix before required checks go on:** that PR is opened with the default
`GITHUB_TOKEN`, and GitHub deliberately does NOT run `pull_request` workflows for PRs
created that way — so the docs PR would never run actionlint/CI/CodeQL and could never
satisfy required checks. Two ways to handle, pick one:
- Open the PR with a GitHub App or machine-account token so the checks run, **or**
- Exempt the `auto-docs/*` branch from the rule set (docs PRs only touch Markdown).

The same "bot PRs don't trigger workflows / get a restricted token" issue applies to
Dependabot PRs — exempt `dependabot/*` from the required-review rule or add Dependabot to
the bypass list, or they get stuck too.

---

## Capability 4 — commit messages into the PR body

`pr-autofill.yml` fills the "What Changed" section from the branch's commits. It uses
`contents: read` + `pull-requests: write` (both needed — reading commits requires
`contents: read`), anchors its edit on hidden HTML-comment markers in the PR template (so a
template edit can't silently break it), and now **skips fork and Dependabot PRs** (their
token is read-only, so it could only 403 there). It's not a required check, so it never
blocks a merge.

---

## Enforcement — the org rule set (and how not to lock yourself out)

One org-level rule set on `main`, **scoped to the repos you own** (not "all repositories" —
that would also gate the untouchable `azure-pulumi` infra repos, the repos with no
workflows at all: `rpa-database-reference`, `teams-app-manifests`, and `sipa` which has
`actionlint` + `pr-autofill` but **no CI job** — so require `actionlint` on sipa, not `CI`
or the reviewers). Match the required checks to what each repo actually produces.

Rules:
- **Require status checks:** `CI` (tests), `SonarCloud Code Analysis` (Sonar gate — per repo,
  once bound), `actionlint`, per language `Analyze (python)` or `Analyze (javascript-typescript)`, plus
  `Aikido Security: check code`. Require branches up to date.
- **Require a pull request before merging.** This is what blocks direct pushes to `main`.
- **Required approvals: 1** is appropriate now — there are two developers, so they review
  each other's PRs (the projects repo already requires an approving review). Keep 1 across
  the fleet. The only caveat: GitHub forbids approving your own PR, so on a repo where just
  ONE person ever contributes, a 1-approval rule would block that person — use 0 (or a
  bypass entry) only for such a genuinely single-contributor repo, not fleet-wide.

**Break-glass (configure this BEFORE enforcing — it is what makes an outage survivable):**
- Org rule sets give admins **no** implicit bypass. Configure an explicit **bypass list**
  (org admin and/or a small `release-admins` team), set to **"for pull requests only"** so
  break-glass still goes through a PR but can merge past a wedged check.
- **Test the bypass path once now, while nothing is broken.** Discovering the bypass list is
  empty during an incident is the failure this prevents.
- Keep a one-page runbook: how to merge when a required check is stuck (use the bypass actor,
  or flip the specific check to not-required, or the rule set to a non-enforcing state), and
  how to restore.
- If Sonar/Aikido/CodeQL stay in the required set, keep their wiring identical across repos
  and keep a `SONAR_TOKEN` rotation reminder — an expired token silently reds the check.

**Rollout:** create the rule set scoped to ONE repo first (Team plans may not have the
non-enforcing "Evaluate" mode), confirm the check contexts resolve, then widen the targeting.

---

## Growth and scale (do when the team actually arrives)

- Add `CODEOWNERS` so reviews route to the right person as the team grows (required
  approvals is already 1 — see enforcement above).
- Move off the personal `dev/general/ernest` working branch to short-lived feature branches
  → PR → review → `main`.
- Adopt a **merge queue** instead of relying on "require branches up to date," which
  otherwise serializes merges into a rebase-and-re-run treadmill at ~10 developers (CI
  workflows then need an `on: merge_group` trigger).
- Consider Dependabot auto-merge for low-risk bumps — but only after the gates are required,
  keep it patch-only / human-reviewed for the actions themselves (an action runs in CI with
  your token, so a passing-CI-but-malicious bump is a real risk), and note it needs an
  explicit `permissions:` block (Dependabot's token is read-only) and a gate written for the
  **grouped** PR update-type, not a plain `semver-patch` match.

---

## The infra-repo landmine (hand this to the infra owner)

The three `azure-pulumi-orchestration-*` repos still pin the old shared docs workflow at
`nightly-docs.yml@<old SHA>`. This is now **de-risked from the owned side**: a thin
compatibility shim was restored on the default branch
(`rockpa/.github/.github/workflows/nightly-docs.yml`) that simply calls `weekly-docs.yml`.
So the old path resolves at every future SHA — a forward Dependabot bump on those repos no
longer 404s — and their current old-SHA pin also still works. The fleet did this without
touching the infra repos. Belt-and-suspenders, the infra owner may still exclude the
reusable-workflow ref from their Dependabot or migrate the caller to `weekly-docs.yml`.

---

## Overall rollout order

1. Configure and TEST the bypass list / break-glass.
2. Make the reviewers uniform (done in files: CI job named `CI` fleet-wide, Sonar step
   best-effort so `CI` = tests, deprecated Sonar action migrated) and enable each reviewer
   per repo (import each repo into SonarCloud — org token already covers it, CodeQL default
   setup, Aikido app).
3. actionlint install is checksum-pinned and the repos are clean — run it once per repo.
4. Fix the docs-PR token (or exempt `auto-docs/*`); handle `dependabot/*`.
5. Turn the rule set on, scoped to owned repos, required approvals = 1 (two devs review each
   other; the projects repo already does this). Approval policy can also stay per-repo if you
   prefer — the ruleset's main job is the uniform required CHECKS; the two aggregate fine.
6. Add `CODEOWNERS` and move to the feature-branch flow as the team grows.
7. Merge queue and any auto-merge last.
