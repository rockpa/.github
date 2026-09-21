# rockpa CI/CD Enforcement Architecture — FINAL

**Scope:** the `rockpa` GitHub org (Team plan, 8 seats, 13 private + 1 public repo). The
three `azure-pulumi-orchestration-*` infra repos are out of scope and excluded by every
rule below.

This document supersedes `ci-cd-fleet-standard.md`. It was produced by a 26-agent external
review (10 grounded research passes → architect draft → 12 adversarial red-teams →
verification against the live org → completeness critic → convergence). Every non-obvious
claim cites a docs URL or a `gh` command.

---

## 1. TL;DR

Enforce everything with **two organization-level branch rulesets**, put Dependabot on by
default with **one Code Security Configuration**, make **exactly two checks blocking**
(`Aikido Security: check code` and `CI`), leave Sonar / CodeQL / Copilot **advisory** (they
run and comment on human PRs but never gate), fix the PR-body automation by correcting a
**one-line bug** in the existing workflow, and delete the per-repo classic branch
protections and the cloned per-repo rulesets. That is the whole system: **2 rulesets, 1
config, the CI workflow you already run, and a one-character fix.**

**"Throw out the overengineered mess and just use rulesets?" — Yes, for enforcement.** Two
org rulesets replace *all* per-repo classic branch protection and *all* cloned per-repo
rulesets; that drift-prone layer disappears. But rulesets are only the *enforcement* plane —
they cannot turn Dependabot on (that is the Code Security Configuration) or run a test/lint
(that is the CI workflow file). So: rulesets are the enforcement mechanism, and you need
**two of them, not five**, plus one config and the CI file you already have.

**Two honest limits you must accept up front (GitHub, not us):**
1. **No GitHub-integrated AI reviewer can *block* a merge.** Copilot code review only ever
   posts a *Comment* review, never Approve/Request-changes
   ([docs](https://docs.github.com/en/copilot/how-tos/copilot-on-github/set-up-copilot/configure-code-review)).
   The only AI-assisted reviewer that can be a *required, blocking* gate is **Aikido's
   security check** (SAST). So "AI review required on every PR" is delivered as **Aikido
   required + Copilot advisory** — that is the ceiling of what GitHub allows, not a choice.
2. **"On every PR" has one exception: Dependabot PRs.** Dependabot runs with a read-only
   token and no secrets, so Sonar, CodeQL/Code-Quality, and Aikido *Deep Review* do **not**
   run on its PRs — only `CI` and `Aikido Security: check code` do (verified on Dependabot
   PR #65). That is exactly why those two are the required gates and the rest are advisory:
   requiring anything that skips on bot PRs would strand every Dependabot PR forever.

**Ownership (strong recommendation, not a build blocker):** today the org's only owner is
the `RPA-Root` service account, and Ernest is a **member**
(`gh api orgs/rockpa/memberships/ErnestOstro` → `role: member`) — which is why
`gh api orgs/rockpa/rulesets` 404s for him and why his direct push to `.github/main` is
stuck. `RPA-Root` *can* execute this entire build. But **promote one human to org owner**
so the person who maintains the code can maintain the enforcement plane, and so there is a
human owner if the service account is lost. This is bus-factor insurance, done once.

---

## 2. What actually works on the Team plan (verified)

| Constraint | Verdict | Evidence |
|---|---|---|
| **Org rulesets enforce on private Team repos** | **True — use them.** | Org ruleset `20890577` (`source_type=Organization`, `enforcement=active`) applies to private repo datagate: `gh api repos/rockpa/datagate/rulesets`. Capability: [changelog 2025-06-16](https://github.blog/changelog/2025-06-16-organization-rulesets-now-available-for-github-team-plans/), [rulesets docs](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets). The `/orgs/rockpa/rulesets` 404 is a **member-permission** artifact, not a missing feature. |
| *…but a branch-protection org ruleset does not exist yet* | Net-new owner work | `20890577` is only a `repository_visibility` policy (`target=repository`). It proves org rulesets *reach* private repos; it is **not** branch protection. |
| **GHAS code scanning is OFF on private repos** | Do not gate on it | `gh api repos/rockpa/datagate` → `code_security.status=disabled`; `…/code-scanning/default-setup` → **403** "Code Security must be enabled". A `code_scanning` ("require code scanning results") ruleset rule would wedge every PR. |
| **datagate's `Analyze (python)` is GitHub Code Quality, not GHAS** | Keep it advisory | Check app is `github-actions`, GHAS is off, no `codeql.yml` in `.github/workflows/`. That signature = Code Quality default setup. |
| **`code_quality` ruleset rule is real but paid + skips Dependabot** | Do not hard-gate | GA on Team, **$10/active-committer/mo**, requires Code Quality enabled ([changelog 2026-07-20](https://github.blog/changelog/2026-07-20-github-code-quality-is-now-generally-available/)). Did **not** run on Dependabot PR #65 → requiring it strands every Dependabot PR. Also: it is only enabled on datagate today, not fleet-wide. |
| **Copilot review cannot block a merge** | Advisory only | Copilot only submits a *Comment* review ([docs](https://docs.github.com/en/copilot/how-tos/copilot-on-github/set-up-copilot/configure-code-review)). The `copilot_code_review` rule only *auto-requests*; it is never a merge condition. |
| **Secret/code scanning on private Team repos is paid GHAS** | Not part of "defaults" | Only Dependabot alerts/updates are free on private Team. Config `17` ("GitHub recommended") enables code+secret scanning; making it the new-repo default would bill paid GHAS on every new private repo. |
| **No ruleset "Evaluate"/shadow mode on Team** | Roll out one repo at a time | Evaluate mode is Enterprise-only. Every flip is live. |
| **Aikido `check code` posts on regular AND Dependabot PRs** | The one safe universal gate | PR #64 (regular) and #65 (Dependabot): `Aikido Security: check code` = success on both; `Deep Review` = skipped on #65 → Deep Review stays advisory. App slug `aikido-pr-checks` (app_id 898896). |
| **CI/tests run on Dependabot PRs; Sonar does not** | Require CI, not Sonar | Dependabot triggers Actions with a read-only token / no secrets. CI + actionlint need no secret → post. The Sonar step is `SONAR_TOKEN`-gated → skipped; its `SonarCloud Code Analysis` check is absent on #65. |

---

## 3. The design

Three planes, each owned by exactly one mechanism. Nothing is hand-maintained per repo
after a finite one-time onboarding.

| Plane | Mechanism | New-repo coverage |
|---|---|---|
| **Enforcement** (PR required, force-push blocked, checks required) | 2 org branch rulesets, name-targeted | Automatic |
| **Scanning defaults** (Dependabot alerts + security updates) | 1 Code Security Configuration, default-for-new-repos | Automatic |
| **Authoring** (the checks exist; deps get bumped) | the standard `ci.yml` (tests + actionlint) and per-repo `dependabot.yml` | Copied once at repo birth; its *absence* fails loud |

### 3.1 Enforcement — two org rulesets

Targeting is by **repository-name pattern**, not custom properties. Custom properties
default to `false`, so a forgotten tag would leave a new repo **silently ungated** — the
wrong failure mode for a security control. A uniform name-pattern requirement fails **loud**
(a repo missing a required check produces a visible wedge that forces onboarding) and
auto-includes future repos with zero tagging.

**Ruleset A — "PR required"** (the universal floor):
- Target: **all repos**, excluding `azure-pulumi-orchestration-*`. Branch: `~DEFAULT_BRANCH`.
- Rules: **Require a pull request** (required approvals = **0**) + **Block force pushes**.
- Delivers "PRs protected by default" and "new repos protected by default." It requires no
  check, so it can **never wedge**.

Required approvals are **0**, not 1: a PR author cannot approve their own PR
([GitHub rule](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/approving-a-pull-request-with-required-reviews)),
so on an ~2-active-dev team a required approval freezes every solo repo whenever the other
person is away. **The status checks are the gate**; human review stays a norm (add CODEOWNERS
if wanted), not a merge lock. datagate is already at `required_approving_review_count=0`.

**Ruleset B — "Checks required"** (blocking gates):
- Target: **all repos**, excluding `azure-pulumi-orchestration-*`, `rpa-database-reference`,
  `teams-app-manifests` (doc-only repos that emit no code checks). Branch: `~DEFAULT_BRANCH`;
  "up to date before merge" = **off** (don't serialize merges).
- Required status checks (byte-exact, both verified to post on regular **and** Dependabot PRs):
  - **`Aikido Security: check code`** — the required AI/security gate.
  - **`CI`** — one job carrying tests + actionlint (+ the Sonar scan step as
    `continue-on-error`), on `pull_request` with **no `paths:` filter** (a path-filtered
    required check never reports and wedges forever —
    [docs](https://docs.github.com/en/actions/using-workflows/required-workflows)), on `GITHUB_TOKEN`.

Two required contexts, both proven reliable. A new code repo is gated the moment it has the
standard `ci.yml`; a new docs-only repo wedges **loudly** until someone adds CI or adds it to
B's exclusion — a one-line fix, never a silent gap.

### 3.2 How each reviewer is wired

| Reviewer | Runs on human PRs | Runs on Dependabot PRs | Blocking? | Wiring |
|---|---|---|---|---|
| **Aikido** | Yes | `check code` yes; `Deep Review` no | **Yes** — `Aikido Security: check code` required in B | Install `aikido-pr-checks` org-wide ("All repositories" + auto-onboard new repos). |
| **CI (tests + lint)** | Yes | Yes | **Yes** — `CI` required in B | Standard `ci.yml`; actionlint folded in so there is **one** context and no separate byte-identical file to sync. |
| **SonarCloud** | Yes | No (SONAR_TOKEN-gated) | No (advisory) | Sonar App posts `SonarCloud Code Analysis`; devs see it. Not required → no wedge, no org-Dependabot-secret machinery. |
| **CodeQL / Code Quality** | Only where enabled (datagate today) | No | No (advisory) | `Analyze (…)` keeps posting where present. Paid per-committer; enabling fleet-wide is a separate budget decision (§7). |
| **Copilot review** | Optional (advisory) | No | **Never possible** | Optionally auto-request via a `copilot_code_review` org rule *only if Copilot Business is already paid*; keep "Copilot approvals count toward merge" **OFF**. |
| **Dependabot** | Authors PRs; not a check | — | — | See §3.3. |

Your "aikido, sonarqube, codeql, lint, dependabot **during any PR**" is met by all of them
*running* on human PRs. Only the two that post reliably **everywhere** (including bot PRs)
**block**; making the rest blocking is what caused the wedges and ~$6–9k/yr of metered spend
for overlapping coverage. Be clear-eyed: **CodeQL is advisory and only on datagate today**,
and **nothing except Aikido `check code` + CI runs on Dependabot PRs** — both by design.

### 3.3 Dependabot / scanning defaults

- **Alerts + security updates on by default:** one **custom Code Security Configuration**
  enabling *only* Dependabot alerts + security updates (free on private Team),
  default-for-new-repos = All, applied to the 13 private repos. Do **not** enable
  secret/code scanning here (paid GHAS); do **not** use config `17` as the default.
- **Version updates:** keep the existing per-repo `dependabot.yml` (grouped weekly, datagate's
  deliberate pip exclusion intact). No org-wide toggle exists.
- **Dependabot PRs merge cleanly:** both required checks (`CI`, `Aikido`) post on them. Merge
  via GitHub's native per-PR auto-merge button; no auto-merge workflow (§7).

### 3.4 PR body from commits — fix the one-line bug (this is the automatic fix you asked for)

**Root cause, verified:** `pr-autofill.yml` reports green while doing nothing.
`gh pr view --json body` returns the body with **CRLF**, but the awk `trim()` at
`pr-autofill.yml:62` strips only `[ \t]`, so the HTML-marker line never matches and the
body replacement is a silent no-op; the check "passes" in ~6s. The on-disk template is LF,
so a template line-ending change would not help — the CR is injected by the API.

**Fix (one line, keeps it automatic — which is the requirement):** in the workflow's awk,
strip `\r` as well as spaces/tabs before matching the marker (e.g. `gsub(/[ \t\r]+$/, "")`
or `sub(/\r$/, "")` on each line). Then it populates the "What Changed" section from the
branch commits on every human PR, automatically, with no one having to remember a flag. Keep
the existing `if:` guard that skips fork/Dependabot PRs (their tokens are read-only). As a
zero-infra backstop for authors, also document `gh pr create --fill` (fills title+body from
commits at creation) and set each repo's squash-merge message to "PR title + commit details"
so the permanent commit carries the list — but the one-line awk fix is what finally makes the
*automatic* behavior you asked for actually work.

---

## 4. Implementation (owner actions, wedge-safe order)

> All org-ruleset / config steps are **org-owner** actions — run as `RPA-Root` (or the newly
> promoted human owner). Ernest (member) can do the repo-level file changes (via PR) and the
> break-glass merges, not the org ruleset creation.

**0. Access + unblock.** Promote one human to org owner (bus-factor). Unblock the stuck
`.github` push by branch + PR, not a direct push:
`git push origin main:chore/github-updates` then `gh pr create --base main`.

**1. One-time onboarding of the 8 code repos** (finite, not architecture):
- Land the standard `ci.yml` (job name **`CI`**, `on: pull_request`, no `paths:` filter,
  actionlint folded in) in every code repo. Gaps: `internal-apps-azure-functions-api`,
  `administrative`, `gift-acknowledgement-letter-splitter` emit `test-and-scan` → **rename
  the job to `CI`**; `rpa-plaid-webhook-gateway` and `gift…` have **no CI/actionlint** → add
  the standard `ci.yml`.
- Confirm Aikido `aikido-pr-checks` is installed **All repositories** with new-repo
  auto-onboarding; verify `administrative` and `gift` post `Aikido Security: check code` on a
  live PR.
- On **one live PR per repo**, confirm the byte-exact contexts post: `CI` and
  `Aikido Security: check code`.

**2. Create the Break-glass team** (§6) and note its id:
`gh api /orgs/rockpa/teams/break-glass --jq .id`.

**3. Create Ruleset A** (`gh api -X POST /orgs/rockpa/rulesets --input a.json`):
```json
{ "name": "PR required", "target": "branch", "enforcement": "active",
  "conditions": {
    "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] },
    "repository_name": { "include": ["~ALL"], "exclude": ["azure-pulumi-orchestration-*"] } },
  "rules": [
    { "type": "pull_request", "parameters": { "required_approving_review_count": 0,
      "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false,
      "require_last_push_approval": false, "required_review_thread_resolution": false } },
    { "type": "non_fast_forward" } ],
  "bypass_actors": [ { "actor_id": <BREAK_GLASS_TEAM_ID>, "actor_type": "Team", "bypass_mode": "pull_request" } ] }
```

**4. Roll out Ruleset B one repo at a time** (Team has no shadow mode). Per repo: re-run
checks on all open PRs, confirm green, then add the repo. Excludes infra + the 2 doc-only repos:
```json
{ "name": "Checks required", "target": "branch", "enforcement": "active",
  "conditions": {
    "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] },
    "repository_name": { "include": ["~ALL"],
      "exclude": ["azure-pulumi-orchestration-*", "rpa-database-reference", "teams-app-manifests"] } },
  "rules": [ { "type": "required_status_checks", "parameters": {
    "strict_required_status_checks_policy": false,
    "required_status_checks": [ { "context": "Aikido Security: check code" }, { "context": "CI" } ] } } ],
  "bypass_actors": [ { "actor_id": <BREAK_GLASS_TEAM_ID>, "actor_type": "Team", "bypass_mode": "pull_request" } ] }
```

**5. Create the Dependabot-only Code Security Configuration** (Settings → Code security →
Configurations → New): enable **only** Dependabot alerts + security updates, **Apply to all
repositories**, **Use as default for new repositories = All**. Do not enable secret/code scanning.

**6. Fix PR bodies:** apply the one-line awk `\r` fix to `pr-autofill.yml` (all 9 copies);
document `gh pr create --fill` in the PR template; set each repo's squash-merge message to
"PR title + commit details"
(`gh api -X PATCH repos/rockpa/<r> -F squash_merge_commit_message=COMMIT_MESSAGES -F squash_merge_commit_title=PR_TITLE`).

**7. (Optional) advisory Copilot** org rule with `copilot_code_review`, only if Copilot
Business is already paid; keep "approvals count toward merge" **OFF**.

**8. TEST break-glass** (§6) before considering rollout done.

### What to DELETE
- **datagate's classic branch protection** — it requires context `SonarQube`, which nothing
  posts (`gh api repos/rockpa/datagate/branches/main/protection` →
  `contexts:['SonarQube','Analyze (python)']`, `strict:true`); this is a **live wedge on
  every non-admin datagate PR right now**. Delete it first — it unblocks datagate immediately.
- **All other per-repo classic branch protection.**
- **The cloned per-repo rulesets** — `19472281` (datagate) and `23743509` (`.github`), both
  `source_type=Repository`, name "Code Quality Copilot review for default branch". `23743509`
  has `non_fast_forward` but **no require-PR**, so direct pushes to `.github/main` hang on
  pending CodeQL — replacing it with Ruleset A (require-PR) makes such pushes cleanly
  *rejected*, never stuck. Audit these in the **web UI**, not REST (REST hides
  `code_scanning`/`copilot_code_review` at api-version 2022-11-28).
- **Any plan** to require GHAS `code_scanning`, to make Sonar/CodeQL/Copilot blocking, or to
  add a Dependabot auto-merge `pull_request_target` workflow.

---

## 5. New-repo onboarding

- **Automatic (zero touch):** Ruleset A (PR required + force-push blocked) and the Dependabot
  default config apply the instant the repo exists.
- **One touch, for a code repo:** copy the standard `ci.yml` (that is what makes `CI` post);
  Aikido auto-onboards via the org-wide install. Verify the two contexts on the first PR.
- **Rare — a docs-only repo:** it has no `CI`, so Ruleset B would wedge it loudly. Add its
  name to Ruleset B's `exclude` (one line). It keeps PR protection from Ruleset A.
- **First-push note:** once require-PR is active, a brand-new repo can't take a direct push
  to `main` — seed via a branch + PR. That is protection working, not a bug.

---

## 6. Break-glass + failure modes

- **The escape hatch a member can use:** a **Break-glass team** (2–3 humans including Ernest)
  on each ruleset's `bypass_actors` in **`pull_request` mode** — an audited bypass (written to
  the ruleset audit log), not a permanent hole; normal PRs still enforce every check. This is
  what lets Ernest ship during an outage **without being an org owner**. It is the answer to
  every "a tool is down" case below — independent of the §1 owner-promotion recommendation
  (which is about bus-factor, not outages). **Test it before going live:** open a PR whose
  required check is forced to fail, confirm the team can merge, confirm the bypass is logged.
  Do not flip rulesets to active until this passes.
- **A reviewer/tool is down:** only `CI` and `Aikido` block and approvals are 0, so a solo
  author merges once those are green. If Aikido's App/backend is down (its check stops posting
  on all PRs), the Break-glass team merges the urgent change; the gate resumes when Aikido
  recovers. GitHub has no per-check timeout, so an outage is indistinguishable from a permanent
  failure — the tested bypass is the only safe answer, which is why it is mandatory.
- **A human is unavailable:** approvals = 0 means no PR is ever blocked on a missing reviewer.

---

## 7. Not doing (and why)

- **A custom-property / 5-ruleset capability matrix** — relocates per-repo hand-maintenance
  into tags that **fail open** (a forgotten tag = a silently ungated repo). Two name-targeted
  rulesets fail *loud* and need no tags.
- **Making SonarCloud / CodeQL / Code Quality blocking** — overlapping paid meters
  ($10–30/committer/mo each), each an independent wedge source, and they skip Dependabot PRs.
  Advisory; developers still see every finding.
- **Enabling CodeQL / Code Quality fleet-wide right now** — it is paid per active committer and
  only on datagate today. If you want CodeQL on all code repos, that is a deliberate budget
  decision, made separately; the enforcement design does not depend on it.
- **The GHAS `code_scanning` rule on private repos** — GHAS Code Security is off (403);
  requiring it wedges every PR.
- **Copilot as a required gate / "approvals count toward merge"** — Copilot can only Comment,
  never block; letting an AI satisfy a required human approval is a governance anti-pattern.
  Advisory, OFF.
- **Default-on secret/code scanning** — paid GHAS on private Team; keep the default config to
  the free Dependabot pieces and treat GHAS as a separate, budgeted decision.
- **A Dependabot auto-merge `pull_request_target` workflow** — unrequested, reintroduces
  SHA-pin-in-every-caller drift, is a privilege-escalation surface. Use GitHub's native
  per-PR auto-merge button instead.
- **Requiring ≥1 approval** — authors can't self-approve; on solo repos it freezes all merges.
- **"Require branches up to date" / merge queue** — serializes merges at this scale for no benefit.

---

**The whole system, restated:** 2 org rulesets, 1 Dependabot config, the CI workflow you
already run, and a one-line `\r` fix to `pr-autofill.yml`. Every clever thing that needed
babysitting is deleted. The one real dependency is access — the org owner (`RPA-Root`, ideally
plus one promoted human) runs section 4, and this is a one-afternoon build with no post-hoc churn.
