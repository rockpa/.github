#!/usr/bin/env bash
# =============================================================================
# findings-sweep.sh -- one-shot, cross-repo Sonar + CodeQL findings report.
#
# The "on-demand local sweep": run this (or ask Claude Code to) to see every
# open code-scanning (CodeQL) alert and SonarCloud issue across ALL the org's
# repos in one pass, so findings can be triaged / fixed without waiting on an
# in-CI bot. Replaces the retired autonomous resolve-findings auto-PR.
#
# Self-updating + clone-free: the repo list is pulled live from the org and the
# Sonar project key is read from each repo's sonar-project.properties ON GITHUB,
# so a brand-new repo is covered automatically with NO edit here (closes the
# goal-3 gap the old hard-coded list had).
#
# Auth:
#   * CodeQL / GitHub  -> uses your `gh` login (gh auth status). No token here.
#   * SonarCloud       -> set SONAR_TOKEN in your env to include Sonar issues;
#                         omit it and the sweep reports CodeQL only.
#                         (A SonarCloud "User Token": My Account -> Security.)
#
# Usage:
#   ./findings-sweep.sh                    # every non-archived repo in the org
#   ./findings-sweep.sh internal-apps-azure-functions-api datagate   # a subset
#   SONAR_TOKEN=xxxx ./findings-sweep.sh   # include Sonar issues
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

echo "=================================================================="
echo " Findings sweep -- org $ORG -- $(date -u '+%Y-%m-%d %H:%M UTC')"
echo " Repos: ${#REPOS[@]}    Sonar: $([ -n "${SONAR_TOKEN:-}" ] && echo 'ON' || echo 'OFF (set SONAR_TOKEN to include)')"
echo "=================================================================="

TOTAL_CQ=0
TOTAL_SN=0

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
          "https://sonarcloud.io/api/issues/search?componentKeys=$key&resolved=false&ps=100" \
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
done

echo
echo "=================================================================="
echo " TOTAL open: CodeQL=$TOTAL_CQ  Sonar=$TOTAL_SN"
echo "=================================================================="
