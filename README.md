# RPA's `.github` Repository

Welcome! This is Rockefeller Philanthropy Advisors' special `.github` repository.
GitHub gives every organization one repo with this exact name and treats it
differently from a normal code repo:

- Anything under `.github/workflows/` here is a **reusable GitHub Actions
  workflow** — shared automation that any other RPA repo can call instead of
  building its own copy.
- `profile/README.md` is the page GitHub shows on the organization's public
  profile (`github.com/rockpa`).
- `.githooks/` holds an optional local git hook that any repo can turn on.

This README explains the big picture — what shared automation exists, how a
repo signs up for it, and what one-time setup it needs. For the full detail on
each workflow (exactly what it does, every input/secret, and a ready-to-copy
example caller file), see
[`docs/reusable-workflows.md`](docs/reusable-workflows.md).

## The big picture: shared workflows + thin callers

Two pieces of automation live here, written once and used by every repo in
the org:

| Workflow | What it does | Runs |
|---|---|---|
| **Nightly Docs** (`nightly-docs.yml`) | Has Claude read a repo's code and Markdown docs and open a pull request with the smallest edits needed to keep the docs accurate. | Once a night (only if the repo had commits in the last 25 hours), or on manual trigger. |
| **Resolve Findings** (`resolve-findings.yml`) | Collects a repo's open CodeQL and Sonar findings, has Claude fix as many as it safely can, and opens a pull request with the fixes. | Right after the repo's CodeQL scan finishes, or on manual trigger. |

Neither workflow ever pushes straight to a repo's default branch — both only
open a pull request for a person to review and merge.

A repo doesn't copy this logic in, it *calls* it. Each repo keeps a tiny
"caller" workflow file (a dozen or so lines) that just says "run the shared
version of this, on this schedule, using the org's shared secrets." All the
real logic — the prompt Claude is given, which files it's allowed to touch,
how the pull request is built — lives here, in one place. Change it here
once, and every repo that calls it picks up the change on its next run.

`datagate` is currently the reference example of a repo that has opted into
both workflows — see its `.github/workflows/nightly-docs.yml` and
`resolve-findings.yml` for real, working caller files.

## One-time setup an org admin needs to do

Both shared workflows are gated so only approved repos can call them, and
both need a couple of org-level settings turned on:

1. **Let other repos call these workflows.** In `rockpa/.github` → Settings →
   Actions → General → Access, set "Accessible from repositories owned by
   rockpa".
2. **Add the org secret `CLAUDE_CODE_OAUTH_TOKEN`.** This is a Claude
   subscription token (created by running `claude setup-token`), stored once
   at the organization level and made available to any repo that needs it.
   Both workflows use it to run Claude. Runs bill to the subscription, not to
   per-call API usage.
3. **(Optional) Add the org secret `SONAR_TOKEN`.** Only needed for repos
   that use SonarCloud. If it's missing anywhere, Resolve Findings just skips
   Sonar for that repo and handles CodeQL findings only.
4. **In each repo that opts in**, turn on Settings → Actions → General →
   "Allow GitHub Actions to create and approve pull requests." Without this,
   a workflow can prepare its fix or doc update, but the final "open a pull
   request" step fails.

## What a repo does to opt in

A repo adds one short workflow file that calls the shared one and forwards
the org's secrets automatically with `secrets: inherit`. See
[`docs/reusable-workflows.md`](docs/reusable-workflows.md) for the exact
caller file to copy for each workflow.

## Local dev: the pre-push test hook

`.githooks/pre-push` is an optional script any repo can turn on to stop a
broken push before it ever reaches CI. It runs the repo's tests — Python
`pytest tests/` if there's a `tests/` folder, or `npm test` if `package.json`
defines a `test` script — and blocks the push if they fail. If a repo has
neither, it does nothing.

It's off by default in every clone. To turn it on locally:

```
git config core.hooksPath .githooks
```

To skip it for a single push: `git push --no-verify`.

This script is meant to be copied — `rpa-ai-azure-orchestration` and `sipa`
already carry their own identical copy of `.githooks/pre-push`. There's no
central mechanism that shares it automatically the way the two reusable
workflows above do; a repo that wants it copies the file in.

---

Questions, thoughts, ideas? Please reach out to the RPA Technology Team!
