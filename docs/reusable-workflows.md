# Reusable workflows — full reference

This page explains, in detail, the two reusable GitHub Actions workflows that
live in this repository (`.github/workflows/nightly-docs.yml` and
`.github/workflows/resolve-findings.yml`) and how another RPA repo calls
them. For the big picture — why these exist and the one-time org setup — see
the main [README](../README.md) first.

## How the caller / shared-workflow pattern works

GitHub Actions lets one workflow file "call" another with a `uses:` line, the
same way a program calls a shared function. The workflow being called can
live in a different repository — that's what happens here:

- **This repo** (`rockpa/.github`) holds the real logic. Both
  `nightly-docs.yml` and `resolve-findings.yml` start with
  `on: workflow_call:`, which is what marks a workflow as "callable from
  elsewhere" rather than only runnable inside this repo.
- **Every repo that opts in** keeps a short "caller" file — usually 10–20
  lines — that does three things: decides when to run (a schedule, a
  trigger, or a manual button), declares the permissions the shared workflow
  is allowed to use, and has one job that reads
  `uses: rockpa/.github/.github/workflows/<name>.yml@main` with
  `secrets: inherit` (which forwards the calling repo's available secrets,
  including the org-level ones, into the shared workflow).

Because the logic lives in one place, a change to the prompt, the model, or a
guardrail is made once, here, and every repo picks it up automatically the
next time its caller runs — nothing to copy-paste and keep in sync.

## Nightly Docs (`nightly-docs.yml`)

**What it does:** once a night, Claude reads the calling repo's code and its
Markdown docs (`README.md`, `docs/**`, any `*.md`) and makes the smallest
edits needed to bring the docs back in line with the code — module/file
names, function signatures, config keys, CLI commands, env vars, architecture
that changed. If something is genuinely undocumented, it can add a short new
section, but it's told not to rewrite things wholesale or reformat sections
that are already correct. If the docs are already accurate, it makes no
changes at all. The result is opened as a pull request — it never edits the
default branch directly.

**When it runs:** on the calling repo's own schedule (each repo's caller
file sets its own cron time), or any time someone clicks "Run workflow" in
the Actions tab. Before doing any work, it checks whether the repo had at
least one commit in the last 25 hours; if not, it skips entirely — no Claude
call, no cost — unless it was triggered manually.

**What it's allowed to touch:** only `Read`, `Glob`, `Grep`, `Edit`, `Write`
— no `Bash`, no network access. It genuinely cannot run code or reach outside
the files it's given.

**What a calling repo must provide:**
- The org secret `CLAUDE_CODE_OAUTH_TOKEN`, forwarded automatically via
  `secrets: inherit`.
- `contents: write`, `pull-requests: write`, and `id-token: write`
  permissions granted in its own caller file. (A caller can only hand the
  shared workflow permissions it already has itself — the org default is
  read-only, so each caller has to explicitly turn these three on.)
- "Allow GitHub Actions to create and approve pull requests" turned on in
  the repo's own Settings → Actions → General (otherwise the final "open a
  pull request" step fails).

**Example caller** (from `datagate`'s
`.github/workflows/nightly-docs.yml`):

```yaml
name: Nightly Docs Refresh

on:
  schedule:
    - cron: '13 8 * * *'   # GitHub cron is UTC, no DST
  workflow_dispatch: {}

permissions:
  contents: write
  pull-requests: write
  id-token: write

jobs:
  docs:
    uses: rockpa/.github/.github/workflows/nightly-docs.yml@main
    secrets: inherit
```

**Resulting pull request:** branch `auto-docs/nightly`, labeled
`documentation` and `automated`, branch deleted automatically after
merge/close. If a docs PR is closed without merging, the next scheduled run
just opens a fresh one — nothing is lost.

## Resolve Findings (`resolve-findings.yml`)

**What it does:** gathers a repo's currently-open code scanning findings from
two sources — CodeQL alerts already inside GitHub, and, optionally,
SonarCloud issues read directly from Sonar's API — and, if there are any,
asks Claude to fix as many as it safely can, run the repo's tests if there's
a `tests/` folder, and open one pull request with the fixes. A finding Claude
judges to be a false alarm, or something needing a human call (an
intentional security warning, a protocol requirement, etc.), is left alone
and explained in the workflow's run log instead of being force-fixed. If
there are zero open findings, both the fix step and the pull-request step are
skipped — the run is a no-op.

**When it runs:** right after the calling repo's own CodeQL scan finishes
(triggered by watching for a workflow literally named "CodeQL" to complete),
or on manual "Run workflow." This means a repo needs code scanning that
produces a workflow run named "CodeQL" — the org standard is GitHub's
built-in "default setup" for code scanning (turned on per-repo under
Settings → Code security, no workflow file required), not something that
lives in this repo.

**What it's allowed to touch:** `Read`, `Glob`, `Grep`, `Edit`, `Write`, and
`Bash` — a wider tool set than Nightly Docs gets, because verifying a real
fix sometimes means running the test suite.

**Sonar project key:** if the calling repo has a `sonar-project.properties`
file with a `sonar.projectKey=` line, that key is used; otherwise it
defaults to `rockpa_<repo-name>`. The Sonar organization is always `rockpa`.

**What a calling repo must provide:**
- The org secret `CLAUDE_CODE_OAUTH_TOKEN` (the same one Nightly Docs uses),
  forwarded via `secrets: inherit`.
- The org secret `SONAR_TOKEN` — optional, only needed if the repo uses
  SonarCloud. Without it, Sonar findings are simply skipped and only CodeQL
  findings are handled.
- `contents: write`, `pull-requests: write`, `security-events: read` (to
  read the repo's own CodeQL alerts), and `id-token: write` permissions
  granted in its own caller file.
- Code scanning (CodeQL) already enabled on the repo, since this workflow
  only fires after a workflow named "CodeQL" completes.
- "Allow GitHub Actions to create and approve pull requests" turned on, same
  as Nightly Docs.

**Example caller** (from `datagate`'s
`.github/workflows/resolve-findings.yml`):

```yaml
name: Resolve Findings

on:
  workflow_run:
    workflows: ["CodeQL"]
    types: [completed]
  workflow_dispatch: {}

permissions:
  contents: write
  pull-requests: write
  security-events: read
  id-token: write

jobs:
  resolve:
    if: ${{ github.event_name == 'workflow_dispatch' || github.event.workflow_run.conclusion == 'success' }}
    uses: rockpa/.github/.github/workflows/resolve-findings.yml@main
    secrets: inherit
```

**Resulting pull request:** branch `auto-fix/code-scanning`, labeled
`automated` and `code-scanning`, branch deleted automatically after
merge/close.

## Shared behavior between both workflows

- **Concurrency:** each shared workflow runs in its own concurrency group
  (`nightly-docs` / `resolve-findings`) so overlapping runs queue up instead
  of racing each other; neither cancels a run already in progress.
- **Model:** both currently run Claude with `--model claude-sonnet-5` and
  `--permission-mode acceptEdits`, and cap the conversation at a fixed number
  of turns (80 for Nightly Docs, 120 for Resolve Findings, since fixing code
  and running tests takes more back-and-forth than editing docs).
- **Pinned actions:** the external actions each workflow uses
  (`actions/checkout`, `anthropics/claude-code-action`,
  `peter-evans/create-pull-request`) are pinned to an exact commit SHA rather
  than a version tag — a security best practice, since a tag can be moved to
  point at different code later but a commit SHA cannot. Bumping one of these
  pins (e.g. to pick up a new Claude Code Action release) is a one-line
  change made once, here, and every caller repo picks it up automatically.
