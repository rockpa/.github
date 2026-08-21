# Code publishing structure (all RPA repos)

**This is the canonical, org-wide reference for how every `rockpa` repository
builds, scans, documents, and ships its code.** Individual repos link here from
their own `docs/code-publishing.md` instead of each re-explaining it — so the
rules live in exactly one place and can't drift repo-to-repo.

If you're setting up a **new repo**, jump to [New repositories](#new-repositories).

---

## The idea in one line

We separate **"managing the code with AI"** (quality, security, and docs —
identical for every repo) from **"deploying the app"** (infrastructure design —
unique to each app). The first is standardized and inherited automatically; the
second stays with the app.

---

## The three layers

| Layer | Lives in | What it is |
|-------|----------|------------|
| **Shared logic** | this repo (`rockpa/.github`) | Reusable workflows (docs refresh, etc.) + shared scripts. Written once; every repo calls it. See [`reusable-workflows.md`](reusable-workflows.md). |
| **Per-repo wiring** | each repo's `.github/workflows/` | Thin, near-identical files: `ci.yml` (Sonar), `nightly-docs.yml` (calls the shared workflow). |
| **Org defaults** | GitHub org **Settings → Code security** | The "GitHub recommended" code-security configuration, set to auto-apply to **all** and **new** repos → CodeQL runs everywhere with no per-repo file. |

---

## What every repo gets (the "code management with AI" baseline)

1. **Code quality — SonarCloud** (`.github/workflows/ci.yml`)
   - Runs on every push and pull request: runs the tests with coverage, then a
     SonarCloud scan.
   - **Sonar identity:** the project key is `rockpa_<sonar-project-name>`. New
     repos derive it from the repo name automatically
     (`-Dsonar.projectKey=rockpa_${{ github.event.repository.name }}`); older
     repos pin it in `sonar-project.properties`. Either way, no drift.
   - **The scan step is skipped until `SONAR_TOKEN` is set**, so CI is green on
     the tests alone until Sonar is deliberately turned on for that repo.

2. **Code security — CodeQL** (org-level, no file)
   - Provided by the org's "GitHub recommended" code-security configuration,
     which auto-attaches to every repo (existing and new). Findings appear in
     the repo's **Security** tab and as pull-request checks.

3. **Docs refresh — weekly** (`.github/workflows/nightly-docs.yml`)
   - A thin caller to the shared workflow in this repo. On a schedule it asks
     Claude to refresh the repo's docs and **opens a pull request** — never
     commits to `main` directly.

> **Deploy is deliberately NOT part of this baseline.** How an app ships
> (private vs public endpoint, which runner, which Azure auth) is app design,
> not code management — see [Deploying](#deploying-app-specific).

---

## Seeing and acting on findings — the on-demand sweep

We do **not** run an autonomous in-CI bot that opens fix PRs (it created a
feedback storm and was retired). Instead findings surface in two ways:

1. **Passively** — CodeQL + Sonar results land in the **Security** tab and as
   **required PR checks**, so nothing merges silently over an open finding.
2. **Actively, on demand** — [`scripts/findings-sweep.sh`](../scripts/findings-sweep.sh)
   pulls every open CodeQL alert (via `gh`) and SonarCloud issue (via
   `SONAR_TOKEN`) across **all** the org's repos in one pass. It reads the repo
   list live and each repo's real Sonar key from GitHub, so a brand-new repo is
   covered with no edit.

   ```bash
   # all non-archived org repos (CodeQL only):
   .github/scripts/findings-sweep.sh
   # include SonarCloud issues:
   SONAR_TOKEN=xxxx .github/scripts/findings-sweep.sh
   # just some repos:
   .github/scripts/findings-sweep.sh internal-apps-azure-functions-api datagate
   ```

   Ask Claude Code to "run the findings sweep" and it will read the report and
   help triage / fix.

---

## Hardening conventions (apply to every workflow)

- **Pin actions to a full commit SHA** (with a `# vN` comment), never a floating
  tag — supply-chain safety. **Dependabot** (with the `github-actions` ecosystem
  enabled) keeps the pins fresh.
- **Every workflow declares `permissions:`** at the least privilege it needs
  (usually `contents: read`; a job that pushes tags needs `contents: write`).
  This also clears CodeQL's `actions/missing-workflow-permissions`.
- **Deploy workflows declare `concurrency: { group: deploy,
  cancel-in-progress: false }`** so a new push waits for an in-flight deploy
  instead of racing it.
- **SonarCloud "Automatic Analysis" must be OFF** for each project — CI-based
  scanning and auto-analysis are mutually exclusive.

---

## New repositories

1. Create the repo from the matching template — **`rpa-repo-template-azure-functions`**
   (Python) or **`rpa-repo-template-azure-swa`** (JS SWA). It arrives with
   `ci.yml`, `sonar-project.properties`, `nightly-docs.yml`, and this doc's
   pointer already in place.
2. **CodeQL** attaches automatically (org config) — nothing to do.
3. To turn **Sonar** on (optional, when you want it): create the SonarCloud
   project `rockpa_<repo>` with **Automatic Analysis OFF**, then add the repo
   secret **`SONAR_TOKEN`**. Until then CI stays green on tests.
4. Add the app's **own** `deploy.yml` — this is the only app-specific piece.

Everything else is inherited; there is nothing to hand-copy.

---

## Deploying (app-specific — NOT templated)

Two supported models; pick by whether the app's deploy endpoint is private or
public:

- **Self-hosted runner + managed identity** (`az login --identity`) — for
  **private-endpoint** Function apps (public network access disabled). The
  runner sits inside the VNet; no secrets in GitHub. The RPA internal norm
  (e.g. `internal-apps-azure-functions-api`).
- **GitHub-hosted runner + OIDC** (federated credential) — for **public-endpoint**
  apps. No self-hosted runner; short-lived tokens (e.g. the Plaid gateway).
- **Static Web Apps** deploy via the SWA deploy token on a GitHub-hosted runner.

These live in each app's own `deploy.yml`; they are intentionally absent from
the templates.

---

## Pointers

Each repo carries a one-screen `docs/code-publishing.md` that links back here and
notes only what's unique to that repo (its deploy model). When something about
the *shared* structure changes, update **this** file — the repo pointers don't
need to change.
