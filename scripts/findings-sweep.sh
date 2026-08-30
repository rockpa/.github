#!/usr/bin/env bash
# =============================================================================
# findings-sweep.sh -- one-shot, cross-repo Sonar + CodeQL + Aikido findings report.
#
# The "on-demand local sweep": run this (or ask Claude Code to) to see every
# open code-scanning (CodeQL) alert, SonarCloud issue, and Aikido security
# finding across ALL the org's repos in one pass, so findings can be triaged /
# fixed without waiting on an in-CI bot.
#
# Self-updating + clone-free: the repo list is pulled live from the org and the
# Sonar project key is read from each repo's sonar-project.properties ON GITHUB,
# so a brand-new repo is covered automatically with NO edit here.
#
# Auth (each source is optional; omit its creds and that source is skipped):
#   * CodeQL / GitHub  -> uses your `gh` login (gh auth status). No token here.
#   * SonarCloud       -> set SONAR_TOKEN in your env (My Account -> Security).
#   * Aikido           -> set AIKIDO_CLIENT_ID + AIKIDO_CLIENT_SECRET (a
#                         workspace-admin API credential with basics:read +
#                         issues:read, from Aikido -> Integrations). Pulled once
#                         for the whole org and filtered per repo below.
#
# SECRETS NOTE: Aikido `leaked_secret` findings are reported as a COUNT ONLY --
# their file locations are NOT printed here (rotate them from the Aikido
# dashboard). This keeps the sweep safe to run and off the secrets boundary.
#
# Usage:
#   ./findings-sweep.sh                    # every non-archived repo in the org
#   ./findings-sweep.sh datagate           # a subset
#   SONAR_TOKEN=xxxx AIKIDO_CLIENT_ID=… AIKIDO_CLIENT_SECRET=… ./findings-sweep.sh
# =============================================================================
set -uo pipefail

ORG="rockpa"

# Repo list: explicit args if given, else ALL non-archived repos in the org
# (live -> a new repo is swept automatically).
if [ "$#" -gt 0 ]; then
  REPOS=("$@")
else
  mapfile -t REPOS < <(gh repo list "$ORG" --no-archived --limit 300 --json name -q '.[].name' | sort)
fi

# The real Sonar project key for a repo: read sonar.projectKey from its
# sonar-project.properties on GitHub (authoritative -- some repos' keys differ
# from their GitHub name). Fall back to the org convention for template-derived
# repos that omit it (their CI passes -Dsonar.projectKey=<ORG>_<repo>).
sonar_key() {
  local name="$1" props key
  props="$(gh api "repos/$ORG/$name/contents/sonar-project.properties" \
             -q '.content' 2>/dev/null | base64 -d 2>/dev/null)"
  key="$(printf '%s' "$props" | grep -E '^sonar\.projectKey=' | head -1 | cut -d= -f2- | tr -d '[:space:]')"
  printf '%s' "${key:-${ORG}_${name}}"
}

# ---- Aikido prefetch: one org-wide pull of open issues, filtered per repo ----
# Aikido's API is org-scoped (not per-repo like the others), so we authenticate
# once (OAuth2 client-credentials) and dump all open issues to a temp file that
# the per-repo loop filters by code_repo_name.
AIK_ON=""
AIK_JSON=""
if [ -n "${AIKIDO_CLIENT_ID:-}" ] && [ -n "${AIKIDO_CLIENT_SECRET:-}" ]; then
  AIK_BASE="https://app.aikido.dev"   # this workspace's API host (not app.us.*)
  AIK_TOKEN="$(curl -s -u "$AIKIDO_CLIENT_ID:$AIKIDO_CLIENT_SECRET" \
                 -d grant_type=client_credentials "$AIK_BASE/api/oauth/token" \
               | python -c 'import sys,json
try: print(json.load(sys.stdin).get("access_token","") or "")
except Exception: print("")')"
  if [ -n "$AIK_TOKEN" ]; then
    AIK_JSON="$(mktemp)"
    python - "$AIK_BASE" "$AIK_TOKEN" "$AIK_JSON" <<'PY'
import sys, json, urllib.request
base, token, out = sys.argv[1], sys.argv[2], sys.argv[3]
allx = []
for page in range(0, 40):
    url = f"{base}/api/public/v1/issues/export?format=json&filter_status=open&per_page=100&page={page}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        chunk = json.loads(urllib.request.urlopen(req, timeout=30).read())
    except Exception:
        break
    if not isinstance(chunk, list) or not chunk:
        break
    allx += chunk
    if len(chunk) < 100:
        break
json.dump(allx, open(out, "w"))
PY
    AIK_ON="yes"
  else
    echo "WARN: Aikido creds set but token exchange failed; skipping Aikido." >&2
  fi
fi
# Clean up the prefetch temp file however the script exits.
trap '[ -n "${AIK_JSON:-}" ] && rm -f "$AIK_JSON"' EXIT

echo "=================================================================="
echo " Findings sweep -- org $ORG -- $(date -u '+%Y-%m-%d %H:%M UTC')"
echo " Repos: ${#REPOS[@]}    Sonar: $([ -n "${SONAR_TOKEN:-}" ] && echo 'ON' || echo 'OFF')    Aikido: $([ -n "$AIK_ON" ] && echo 'ON' || echo 'OFF')"
echo "=================================================================="

TOTAL_CQ=0
TOTAL_SN=0
TOTAL_AIK=0

for name in "${REPOS[@]}"; do
  slug="$ORG/$name"
  echo
  echo "### $name"

  # ---- CodeQL / code-scanning (open alerts, all pages) -----------------------
  cq="$(gh api --paginate "repos/$slug/code-scanning/alerts?state=open&per_page=100" \
        -q '.[] | "  [\(.rule.security_severity_level // .rule.severity)] \(.rule.id)  \(.most_recent_instance.location.path):\(.most_recent_instance.location.start_line)"' \
        2>/dev/null)"
  if [ $? -ne 0 ]; then
    echo "  CodeQL: (code scanning not enabled or no access)"
  elif [ -z "$cq" ]; then
    echo "  CodeQL: none open"
  else
    n="$(printf '%s\n' "$cq" | grep -c .)"; TOTAL_CQ=$((TOTAL_CQ + n))
    echo "  CodeQL: $n open"
    printf '%s\n' "$cq"
  fi

  # ---- SonarCloud (open issues) ---------------------------------------------
  if [ -n "${SONAR_TOKEN:-}" ]; then
    key="$(sonar_key "$name")"
    sn="$(curl -s -u "$SONAR_TOKEN:" \
          "https://sonarcloud.io/api/issues/search?componentKeys=$key&organization=$ORG&resolved=false&ps=100" \
          | python -c 'import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for i in d.get("issues",[]):
    print("  [%s] %s  %s:%s" % (i.get("severity"), i.get("rule"), i.get("component","").split(":")[-1], i.get("line","")))' 2>/dev/null)"
    if [ -z "$sn" ]; then
      echo "  Sonar:  none open / no project ($key)"
    else
      n="$(printf '%s\n' "$sn" | grep -c .)"; TOTAL_SN=$((TOTAL_SN + n))
      echo "  Sonar:  $n open (project $key)"
      printf '%s\n' "$sn"
    fi
  fi

  # ---- Aikido (open issues for this repo, from the org-wide prefetch) --------
  # First output line is the finding COUNT (incl. secrets); the rest is detail.
  # leaked_secret is collapsed to a single count line -- locations stay in the
  # dashboard (secrets boundary), everything else prints file:line + rule.
  if [ -n "$AIK_ON" ]; then
    ak="$(python - "$AIK_JSON" "$name" <<'PY'
import sys, json
data = json.load(open(sys.argv[1])); repo = sys.argv[2]
rows = [i for i in data if i.get("code_repo_name") == repo]
secrets = [i for i in rows if i.get("type") == "leaked_secret"]
other = [i for i in rows if i.get("type") != "leaked_secret"]
print(len(rows))  # line 1 = count
for i in sorted(other, key=lambda x: -(x.get("severity_score") or 0)):
    loc = f'{i.get("affected_file") or i.get("domain_name") or ""}:{i.get("start_line") or ""}'.rstrip(":")
    print(f'  [{i.get("severity")}] {i.get("type")}  {loc}  {i.get("rule") or ""}')
if secrets:
    print(f'  [{len(secrets)}] leaked_secret  (rotate from the Aikido dashboard -- locations not listed here)')
PY
)"
    n="$(printf '%s\n' "$ak" | head -1)"
    detail="$(printf '%s\n' "$ak" | tail -n +2)"
    if [ "${n:-0}" = "0" ] || [ -z "${n:-}" ]; then
      echo "  Aikido: none open"
    else
      TOTAL_AIK=$((TOTAL_AIK + n))
      echo "  Aikido: $n open"
      printf '%s\n' "$detail"
    fi
  fi
done

echo
echo "=================================================================="
echo " TOTAL open: CodeQL=$TOTAL_CQ  Sonar=$TOTAL_SN  Aikido=$TOTAL_AIK"
echo "=================================================================="
