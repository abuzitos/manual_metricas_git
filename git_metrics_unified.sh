#!/usr/bin/env bash
set -euo pipefail

# git_metrics_unified.sh — Coleta métricas via Git + (GitHub | Azure DevOps | Bitbucket).
# Requisitos comuns: git, jq
#  - GitHub: GitHub CLI (gh) autenticado: `gh auth login`
#  - Azure DevOps: Azure CLI (az) + extensão azure-devops
#  - Bitbucket: curl + credenciais (env: BB_USER, BB_APP_PASS) ou use um netrc
#
# Uso (Bitbucket Cloud):
#   ./git_metrics_unified.sh --provider bitbucket --workspace "WORK" --repo "repo-slug" \
#       --since "2025-01-01" --until "2025-01-31"
#
# Saída: JSON com as métricas padronizadas.
#
have() { command -v "$1" >/dev/null 2>&1; }
die() { echo "Erro: $*" >&2; exit 1; }

iso_today() { date -u +"%Y-%m-%d"; }
iso_days_ago() { local d="${1:-30}"; date -u -d "-$d days" +"%Y-%m-%d"; }

date_diff_hours() {
  local a="$1" b="$2"
  local ta tb
  ta=$(date -d "$a" +%s 2>/dev/null || true)
  tb=$(date -d "$b" +%s 2>/dev/null || true)
  [[ -z "$ta" || -z "$tb" ]] && die "date(1) não conseguiu parsear datas ($a | $b)."
  awk -v a="$ta" -v b="$tb" 'BEGIN { printf("%.2f", (b-a)/3600.0) }'
}

calc_percent() {
  local add="$1" del="$2"
  local total=$(( add + del ))
  if [[ "$total" -eq 0 ]]; then
    echo "0.00 0.00"
  else
    awk -v a="$add" -v d="$del" 'BEGIN { t=a+d; printf("%.2f %.2f", (a*100.0)/t, (d*100.0)/t) }'
  fi
}

# ---------- Args ----------
PROVIDER=""
SINCE="$(iso_days_ago 30)"
UNTIL="$(iso_today)"
WINDOW_DAYS=21

# GitHub
GH_REPO=""              # owner/name

# Azure DevOps
AZ_ORG=""
AZ_PROJECT=""
AZ_REPO_NAME=""
AZ_PIPELINE_IDS=""
AZ_USE_RELEASES=false

# Bitbucket
BB_WORKSPACE=""
BB_REPO_SLUG=""
BB_API="https://api.bitbucket.org/2.0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) PROVIDER="$2"; shift 2;;
    --since) SINCE="$2"; shift 2;;
    --until) UNTIL="$2"; shift 2;;
    --window-days) WINDOW_DAYS="$2"; shift 2;;

    # GitHub
    --repo) 
      if [[ "${PROVIDER:-}" == "azure" ]]; then AZ_REPO_NAME="$2";
      elif [[ "${PROVIDER:-}" == "bitbucket" ]]; then BB_REPO_SLUG="$2";
      else GH_REPO="$2"; fi
      shift 2;;
    --gh-repo) GH_REPO="$2"; shift 2;;

    # Azure
    --org) AZ_ORG="$2"; shift 2;;
    --project) AZ_PROJECT="$2"; shift 2;;
    --az-repo) AZ_REPO_NAME="$2"; shift 2;;
    --pipeline-ids) AZ_PIPELINE_IDS="$2"; shift 2;;
    --use-releases) AZ_USE_RELEASES=true; shift 1;;

    # Bitbucket
    --workspace) BB_WORKSPACE="$2"; shift 2;;

    *) die "Parâmetro desconhecido: $1";;
  esac
done

[[ -z "$PROVIDER" ]] && die "Informe --provider github|azure|bitbucket"

have git || die "git não encontrado."
have jq || die "jq não encontrado."

# ---------- Git-only metrics ----------
commit_frequency() {
  git rev-list --count --since="$SINCE" --until="$UNTIL" HEAD
}

coding_time_hours() {
  local first last
  first=$(git log --since="$SINCE" --until="$UNTIL" --pretty=format:%ci | tail -1 || true)
  last=$(git log --since="$SINCE" --until="$UNTIL" --pretty=format:%ci | head -1 || true)
  [[ -z "$first" || -z "$last" ]] && { echo "0.00"; return; }
  date_diff_hours "$first" "$last"
}

code_metrics_json() {
  local cutoff
  cutoff=$(date -u -d "$UNTIL -$WINDOW_DAYS days" +"%Y-%m-%dT%H:%M:%SZ")
  git log --since="$SINCE" --until="$UNTIL" --numstat --pretty="---%H %cI" |
  awk -v cutoff="$cutoff" '
    BEGIN { ra=0; rd=0; oa=0; od=0; cur="" }
    /^---/ { cur=$2; next }
    NF==3 && $1 ~ /^[0-9-]+$/ && $2 ~ /^[0-9-]+$/ {
      add=$1; del=$2;
      if (add == "-") add=0; if (del == "-") del=0;
      if (cur >= cutoff) { ra+=add; rd+=del } else { oa+=add; od+=del }
    }
    END { printf("{\"recent\":{\"add\":%d,\"del\":%d},\"old\":{\"add\":%d,\"del\":%d}}", ra, rd, oa, od) }'
}

# ---------- GitHub helpers ----------
detect_github_repo() {
  local url owner name
  url=$(git remote get-url origin 2>/dev/null || true)
  if [[ "$url" =~ github.com[:/]+([^/]+)/([^/.]+) ]]; then
    owner="${BASH_REMATCH[1]}"; name="${BASH_REMATCH[2]}"
    echo "${owner}/${name}"
  fi
}

gh_require() { have gh || die "Requer GitHub CLI (gh)."; }

gh_list_merged_prs() {
  gh_require
  gh pr list --repo "$1" --state merged --search "merged:>=$SINCE merged:<=$UNTIL" --limit 200 \
    --json number,createdAt,updatedAt,mergedAt,labels,title,author,url
}

gh_pr_earliest_commit_iso() {
  local repo="$1" pr_number="$2"
  gh_require
  gh pr view "$pr_number" --repo "$repo" --json commits \
    | jq -r '.commits[].commit.committedDate' | sort | head -1
}

gh_list_releases_json() {
  local repo="$1"
  gh_require
  gh api -X GET "repos/${repo}/releases?per_page=100" | jq '[.[] | {tag_name, name, published_at}]'
}

# ---------- Azure DevOps helpers ----------
az_require() { have az || die "Requer Azure CLI (az) + extensão azure-devops."); }
az_setup_defaults() { az devops configure -d organization="$AZ_ORG" project="$AZ_PROJECT" >/dev/null 2>&1 || true; }
az_repo_id() { az_require; az_setup_defaults; az repos show --repository "$AZ_REPO_NAME" --query id -o tsv; }
az_list_completed_prs_json() {
  az_require; az_setup_defaults
  az repos pr list --repository "$AZ_REPO_NAME" --status completed --output json \
  | jq --arg since "$SINCE" --arg until "$UNTIL" 'map(select(.closedDate != null)) | map(select(.closedDate >= ($since+"T00:00:00Z") and .closedDate <= ($until+"T23:59:59Z")))'
}
az_pr_earliest_commit_iso() {
  local pr_id="$1" repo_id="$2"
  az_require; az_setup_defaults
  az devops invoke \
    --route-parameters organization="$AZ_ORG" project="$AZ_PROJECT" repositoryId="$repo_id" pullRequestId="$pr_id" \
    --area git --resource pullrequestcommits \
    --query "value[].committer.date" --output json 2>/dev/null | jq -r 'sort | .[0] // empty'
}
az_list_releases_json() {
  az_require; az_setup_defaults
  az devops invoke --organization "$AZ_ORG" --http-method GET --route-parameters project="$AZ_PROJECT" \
    --area release --resource releases --query "value[].{name:name, createdOn:createdOn}" --output json --api-version "7.1-preview.8" 2>/dev/null || echo '[]'
}
az_list_pipeline_runs_after_iso() {
  local after_iso="$1"
  az_require; az_setup_defaults
  [[ -z "$AZ_PIPELINE_IDS" ]] && { echo '[]'; return; }
  local out="[]"
  for pid in $AZ_PIPELINE_IDS; do
    local runs
    runs=$(az pipelines runs list --pipeline-ids "$pid" --status completed --result succeeded \
             --query "[].{id:id,finishTime:finishTime}" -o json 2>/dev/null || echo '[]')
    if [[ "$out" == "[]" ]]; then out="$runs"; else out=$(jq -c --argjson a "$out" --argjson b "$runs" '$a + $b' <<<"{}" 2>/dev/null || echo "$runs"); fi
  done
  echo "${out:-[]}"
}

# ---------- Bitbucket helpers ----------
bb_auth() {
  : "${BB_USER:?Defina BB_USER}"
  : "${BB_APP_PASS:?Defina BB_APP_PASS}"
}
bb_list_prs_merged_json() {
  bb_auth
  local url="$BB_API/repositories/$BB_WORKSPACE/$BB_REPO_SLUG/pullrequests?state=MERGED&pagelen=50"
  local out="[]"; local page=1; local fetched
  while :; do
    fetched=$(curl -s -u "$BB_USER:$BB_APP_PASS" "$url&page=$page")
    local vals=$(echo "$fetched" | jq '.values')
    out=$(jq -c --argjson a "$out" --argjson b "$vals" '$a + $b' <<<"{}" 2>/dev/null || echo "$vals")
    local next=$(echo "$fetched" | jq -r '.next // empty')
    [[ -z "$next" || $page -ge 4 ]] && break
    page=$((page+1))
  done
  echo "$out" | jq --arg since "$SINCE" --arg until "$UNTIL" '
    [ .[]
      | select(.updated_on >= ($since+"T00:00:00Z") and .updated_on <= ($until+"T23:59:59Z"))
      | {id: .id, title: .title, created_on: .created_on, updated_on: .updated_on, state: .state}
    ]'
}
bb_list_pipelines_json() {
  bb_auth
  local url="$BB_API/repositories/$BB_WORKSPACE/$BB_REPO_SLUG/pipelines/?sort=-created_on&pagelen=50"
  curl -s -u "$BB_USER:$BB_APP_PASS" "$url" \
    | jq '[ .values[] | {uuid: .uuid, state: .state.name, created_on: .created_on, completed_on: .completed_on} ]'
}

# ---------- Provider-specific metrics ----------
# GitHub
cycle_time_avg_hours_github() {
  local repo="$1" prs total=0.0 n=0
  prs="$(gh_list_merged_prs "$repo")"; n=$(echo "$prs" | jq 'length'); [[ "$n" -eq 0 ]] && { echo "0.00"; return; }
  while IFS= read -r prn; do
    local earliest merged hrs
    earliest=$(gh_pr_earliest_commit_iso "$repo" "$prn")
    merged=$(echo "$prs" | jq -r ".[] | select(.number==$prn) | .mergedAt")
    if [[ -n "$earliest" && -n "$merged" ]]; then
      hrs=$(date_diff_hours "$earliest" "$merged")
      total=$(awk -v t="$total" -v h="$hrs" 'BEGIN{printf("%.6f", t+h)}')
    fi
  done < <(echo "$prs" | jq -r '.[].number')
  awk -v tot="$total" -v n="$n" 'BEGIN { if (n==0) print "0.00"; else printf("%.2f", tot/n) }'
}
review_time_avg_hours_github() {
  local repo="$1" prs total=0.0 n=0
  prs="$(gh_list_merged_prs "$repo")"; n=$(echo "$prs" | jq 'length'); [[ "$n" -eq 0 ]] && { echo "0.00"; return; }
  while IFS= read -r prn; do
    local created updated merged start hrs
    created=$(echo "$prs" | jq -r ".[] | select(.number==$prn) | .createdAt")
    updated=$(echo "$prs" | jq -r ".[] | select(.number==$prn) | .updatedAt")
    merged=$(echo "$prs" | jq -r ".[] | select(.number==$prn) | .mergedAt")
    start="${updated:-$created}"
    if [[ -n "$start" && -n "$merged" ]]; then
      hrs=$(date_diff_hours "$start" "$merged")
      total=$(awk -v t="$total" -v h="$hrs" 'BEGIN{printf("%.6f", t+h)}')
    fi
  done < <(echo "$prs" | jq -r '.[].number')
  awk -v tot="$total" -v n="$n" 'BEGIN { if (n==0) print "0.00"; else printf("%.2f", tot/n) }'
}
pickup_time_avg_hours_github() {
  local repo="$1" prs total=0.0 counted=0
  prs="$(gh_list_merged_prs "$repo")"
  while IFS= read -r prn; do
    local created updated hrs
    created=$(echo "$prs" | jq -r ".[] | select(.number==$prn) | .createdAt")
    updated=$(echo "$prs" | jq -r ".[] | select(.number==$prn) | .updatedAt")
    if [[ -n "$updated" && -n "$created" ]]; then
      hrs=$(date_diff_hours "$created" "$updated")
      total=$(awk -v t="$total" -v h="$hrs" 'BEGIN{printf("%.6f", t+h)}')
      counted=$((counted+1))
    fi
  done < <(echo "$prs" | jq -r '.[].number')
  awk -v tot="$total" -v n="$counted" 'BEGIN { if (n==0) print "0.00"; else printf("%.2f", tot/n) }'
}
deployment_frequency_github() { local repo="$1" prs; prs="$(gh_list_merged_prs "$repo")"; echo "$prs" | jq 'length'; }
deploy_time_avg_hours_github() {
  local repo="$1" prs rels total=0.0 counted=0
  prs="$(gh_list_merged_prs "$repo")"; rels="$(gh_list_releases_json "$repo")"
  while IFS= read -r merged; do
    local rel_date hrs
    rel_date=$(echo "$rels" | jq -r --arg m "$merged" --arg until "$UNTIL" '
      [ .[] | select(.published_at != null) | select(.published_at >= ($m)) | select(.published_at <= ($until+"T23:59:59Z")) | .published_at ] | sort | .[0] // empty ')
    if [[ -n "$rel_date" ]]; then
      hrs=$(date_diff_hours "$merged" "$rel_date")
      total=$(awk -v t="$total" -v h="$hrs" 'BEGIN{printf("%.6f", t+h)}')
      counted=$((counted+1))
    fi
  done < <(echo "$prs" | jq -r '.[].mergedAt')
  awk -v tot="$total" -v n="$counted" 'BEGIN { if (n==0) print "0.00"; else printf("%.2f", tot/n) }'
}
mttr_avg_hours_github() {
  local repo="$1" prs pr_count total=0.0
  prs=$(gh pr list --repo "$repo" --state merged --label bug --search "merged:>=$SINCE merged:<=$UNTIL" --limit 200 --json number,createdAt,mergedAt || echo "[]")
  prs=$(jq -c '. + ( input // [] )' <<<"$prs" <<<"$(gh pr list --repo "$repo" --state merged --label fix --search "merged:>=$SINCE merged:<=$UNTIL" --limit 200 --json number,createdAt,mergedAt 2>/dev/null || echo "[]")")
  pr_count=$(echo "$prs" | jq 'length'); [[ "$pr_count" -eq 0 ]] && { echo "0.00"; return; }
  while IFS= read -r line; do
    local created merged hrs
    created=$(jq -r '.createdAt' <<<"$line")
    merged=$(jq -r '.mergedAt' <<<"$line")
    if [[ -n "$created" && -n "$merged" ]]; then
      hrs=$(date_diff_hours "$created" "$merged")
      total=$(awk -v t="$total" -v h="$hrs" 'BEGIN{printf("%.6f", t+h)}')
    fi
  done < <(echo "$prs" | jq -c '.[]')
  awk -v tot="$total" -v n="$pr_count" 'BEGIN { if (n==0) print "0.00"; else printf("%.2f", tot/n) }'
}
cfr_percent_github() {
  local repo="$1" total failed rollback total_count
  total=$(gh_list_merged_prs "$repo"); total_count=$(echo "$total" | jq 'length')
  [[ "$total_count" -eq 0 ]] && { echo "0.00"; return; }
  failed=$(echo "$total" | jq '[ .[] | select(.labels[]?.name=="failure") ] | length')
  rollback=$(echo "$total" | jq '[ .[] | select(.labels[]?.name=="rollback") ] | length')
  awk -v f="$failed" -v r="$rollback" -v t="$total_count" 'BEGIN { printf("%.2f", ((f+r)*100.0)/t) }'
}

# Azure
cycle_time_avg_hours_azure() {
  local prs total=0.0 n=0 repo_id
  prs="$(az_list_completed_prs_json)"; n=$(echo "$prs" | jq 'length'); [[ "$n" -eq 0 ]] && { echo "0.00"; return; }
  repo_id="$(az_repo_id)"
  while IFS= read -r pr; do
    local id merged earliest hrs
    id=$(jq -r '.pullRequestId' <<<"$pr"); merged=$(jq -r '.closedDate' <<<"$pr")
    earliest=$(az_pr_earliest_commit_iso "$id" "$repo_id")
    if [[ -n "$earliest" && -n "$merged" ]]; then
      hrs=$(date_diff_hours "$earliest" "$merged")
      total=$(awk -v t="$total" -v h="$hrs" 'BEGIN{printf("%.6f", t+h)}')
    fi
  done < <(echo "$prs" | jq -c '.[]')
  awk -v tot="$total" -v n="$n" 'BEGIN { if (n==0) print "0.00"; else printf("%.2f", tot/n) }'
}
review_time_avg_hours_azure() {
  local prs total=0.0 n=0
  prs="$(az_list_completed_prs_json)"; n=$(echo "$prs" | jq 'length'); [[ "$n" -eq 0 ]] && { echo "0.00"; return; }
  while IFS= read -r pr; do
    local created updated merged start hrs
    created=$(jq -r '.creationDate' <<<"$pr")
    updated=$(jq -r '.lastMergeSourceCommit.committer.date // .lastMergeTargetCommit.committer.date // empty' <<<"$pr")
    merged=$(jq -r '.closedDate' <<<"$pr")
    start="${updated:-$created}"
    if [[ -n "$start" && -n "$merged" ]]; then
      hrs=$(date_diff_hours "$start" "$merged")
      total=$(awk -v t="$total" -v h="$hrs" 'BEGIN{printf("%.6f", t+h)}')
    fi
  done < <(echo "$prs" | jq -c '.[]')
  awk -v tot="$total" -v n="$n" 'BEGIN { if (n==0) print "0.00"; else printf("%.2f", tot/n) }'
}
pickup_time_avg_hours_azure() {
  local prs total=0.0 counted=0
  prs="$(az_list_completed_prs_json)"
  while IFS= read -r pr; do
    local created updated hrs
    created=$(jq -r '.creationDate' <<<"$pr")
    updated=$(jq -r '.lastMergeSourceCommit.committer.date // .lastMergeTargetCommit.committer.date // empty' <<<"$pr")
    if [[ -n "$created" && -n "$updated" ]]; then
      hrs=$(date_diff_hours "$created" "$updated")
      total=$(awk -v t="$total" -v h="$hrs" 'BEGIN{printf("%.6f", t+h)}')
      counted=$((counted+1))
    fi
  done < <(echo "$prs" | jq -c '.[]')
  awk -v tot="$total" -v n="$counted" 'BEGIN { if (n==0) print "0.00"; else printf("%.2f", tot/n) }'
}
deployment_frequency_azure() { az_list_completed_prs_json | jq 'length'; }
deploy_time_avg_hours_azure() {
  local prs total=0.0 counted=0
  prs="$(az_list_completed_prs_json)"
  while IFS= read -r pr; do
    local merged first_deploy hrs
    merged=$(jq -r '.closedDate' <<<"$pr")
    if [[ "$AZ_USE_RELEASES" == "true" ]]; then
      local rels; rels=$(az_list_releases_json)
      first_deploy=$(echo "$rels" | jq -r --arg m "$merged" --arg until "$UNTIL" '[ .[] | select(.createdOn >= $m) | .createdOn ] | sort | .[0] // empty')
    else
      local runs; runs=$(az_list_pipeline_runs_after_iso "$merged")
      first_deploy=$(echo "$runs" | jq -r --arg m "$merged" '[ .[] | select(.finishTime >= $m) | .finishTime ] | sort | .[0] // empty')
    fi
    if [[ -n "$first_deploy" ]]; then
      hrs=$(date_diff_hours "$merged" "$first_deploy")
      total=$(awk -v t="$total" -v h="$hrs" 'BEGIN{printf("%.6f", t+h)}')
      counted=$((counted+1))
    fi
  done < <(echo "$prs" | jq -c '.[]')
  awk -v tot="$total" -v n="$counted" 'BEGIN { if (n==0) print "0.00"; else printf("%.2f", tot/n) }'
}
mttr_avg_hours_azure() {
  local prs total=0.0 n=0
  prs="$(az_list_completed_prs_json)"
  prs=$(echo "$prs" | jq '[ .[] | select([.labels[].name] | index("bug") or index("fix")) ]')
  n=$(echo "$prs" | jq 'length'); [[ "$n" -eq 0 ]] && { echo "0.00"; return; }
  while IFS= read -r pr; do
    local created merged hrs
    created=$(jq -r '.creationDate' <<<"$pr"); merged=$(jq -r '.closedDate' <<<"$pr")
    if [[ -n "$created" && -n "$merged" ]]; then
      hrs=$(date_diff_hours "$created" "$merged")
      total=$(awk -v t="$total" -v h="$hrs" 'BEGIN{printf("%.6f", t+h)}')
    fi
  done < <(echo "$prs" | jq -c '.[]')
  awk -v tot="$total" -v n="$n" 'BEGIN { if (n==0) print "0.00"; else printf("%.2f", tot/n) }'
}
cfr_percent_azure() {
  local prs total failed
  prs="$(az_list_completed_prs_json)"; total=$(echo "$prs" | jq 'length'); [[ "$total" -eq 0 ]] && { echo "0.00"; return; }
  failed=$(echo "$prs" | jq '[ .[] | select([.labels[].name] | index("failure") or index("rollback")) ] | length')
  awk -v f="$failed" -v t="$total" 'BEGIN { printf("%.2f", (f*100.0)/t) }'
}

# Bitbucket
cycle_time_avg_hours_bitbucket() {
  local prs total=0.0 n=0
  prs="$(bb_list_prs_merged_json)"; n=$(echo "$prs" | jq 'length'); [[ "$n" -eq 0 ]] && { echo "0.00"; return; }
  while IFS= read -r pr; do
    local created merged hrs
    created=$(jq -r '.created_on' <<<"$pr")
    merged=$(jq -r '.updated_on' <<<"$pr")
    if [[ -n "$created" && -n "$merged" ]]; then
      hrs=$(date_diff_hours "$created" "$merged")
      total=$(awk -v t="$total" -v h="$hrs" 'BEGIN{printf("%.6f", t+h)}')
    fi
  done < <(echo "$prs" | jq -c '.[]')
  awk -v tot="$total" -v n="$n" 'BEGIN { if (n==0) print "0.00"; else printf("%.2f", tot/n) }'
}
review_time_avg_hours_bitbucket() {
  local prs total=0.0 n=0
  prs="$(bb_list_prs_merged_json)"; n=$(echo "$prs" | jq 'length'); [[ "$n" -eq 0 ]] && { echo "0.00"; return; }
  while IFS= read -r pr; do
    local created updated merged start hrs
    created=$(jq -r '.created_on' <<<"$pr")
    updated=$(jq -r '.updated_on' <<<"$pr")
    merged="$updated"
    start="${updated:-$created}"
    if [[ -n "$start" && -n "$merged" ]]; then
      hrs=$(date_diff_hours "$start" "$merged")
      total=$(awk -v t="$total" -v h="$hrs" 'BEGIN{printf("%.6f", t+h)}')
    fi
  done < <(echo "$prs" | jq -c '.[]')
  awk -v tot="$total" -v n="$n" 'BEGIN { if (n==0) print "0.00"; else printf("%.2f", tot/n) }'
}
pickup_time_avg_hours_bitbucket() {
  local prs total=0.0 counted=0
  prs="$(bb_list_prs_merged_json)"
  while IFS= read -r pr; do
    local created updated hrs
    created=$(jq -r '.created_on' <<<"$pr")
    updated=$(jq -r '.updated_on' <<<"$pr")
    if [[ -n "$created" && -n "$updated" ]]; then
      hrs=$(date_diff_hours "$created" "$updated")
      total=$(awk -v t="$total" -v h="$hrs" 'BEGIN{printf("%.6f", t+h)}')
      counted=$((counted+1))
    fi
  done < <(echo "$prs" | jq -c '.[]')
  awk -v tot="$total" -v n="$counted" 'BEGIN { if (n==0) print "0.00"; else printf("%.2f", tot/n) }'
}
deployment_frequency_bitbucket() { bb_list_prs_merged_json | jq 'length'; }
deploy_time_avg_hours_bitbucket() {
  local prs total=0.0 counted=0
  prs="$(bb_list_prs_merged_json)"
  local pipes="$(bb_list_pipelines_json)"
  while IFS= read -r pr; do
    local merged first_deploy hrs
    merged=$(jq -r '.updated_on' <<<"$pr")
    first_deploy=$(echo "$pipes" | jq -r --arg m "$merged" '
      [ .[] | select(.state=="COMPLETED" or .state=="SUCCESSFUL" or .state=="COMPLETED_SUCCESS") |
        select(.completed_on != null and .completed_on >= $m) | .completed_on ] | sort | .[0] // empty')
    if [[ -n "$first_deploy" ]]; then
      hrs=$(date_diff_hours "$merged" "$first_deploy")
      total=$(awk -v t="$total" -v h="$hrs" 'BEGIN{printf("%.6f", t+h)}')
      counted=$((counted+1))
    fi
  done < <(echo "$prs" | jq -c '.[]')
  awk -v tot="$total" -v n="$counted" 'BEGIN { if (n==0) print "0.00"; else printf("%.2f", tot/n) }'
}
mttr_avg_hours_bitbucket() {
  local prs total=0.0 n=0
  prs="$(bb_list_prs_merged_json)"
  prs=$(echo "$prs" | jq '[ .[] | select((.title | test("(?i)\\bfix\\b|\\bbug\\b"))) ]')
  n=$(echo "$prs" | jq 'length'); [[ "$n" -eq 0 ]] && { echo "0.00"; return; }
  while IFS= read -r pr; do
    local created merged hrs
    created=$(jq -r '.created_on' <<<"$pr"); merged=$(jq -r '.updated_on' <<<"$pr")
    if [[ -n "$created" && -n "$merged" ]]; then
      hrs=$(date_diff_hours "$created" "$merged")
      total=$(awk -v t="$total" -v h="$hrs" 'BEGIN{printf("%.6f", t+h)}')
    fi
  done < <(echo "$prs" | jq -c '.[]')
  awk -v tot="$total" -v n="$n" 'BEGIN { if (n==0) print "0.00"; else printf("%.2f", tot/n) }'
}
cfr_percent_bitbucket() {
  local prs total failed
  prs="$(bb_list_prs_merged_json)"; total=$(echo "$prs" | jq 'length'); [[ "$total" -eq 0 ]] && { echo "0.00"; return; }
  failed=$(echo "$prs" | jq '[ .[] | select((.title | test("(?i)rollback|revert|failure"))) ] | length')
  awk -v f="$failed" -v t="$total" 'BEGIN { printf("%.2f", (f*100.0)/t) }'
}

# ---------- Execução ----------
commit_freq=$(commit_frequency)
coding_time=$(coding_time_hours)
code_json=$(code_metrics_json)
recent_add=$(echo "$code_json" | jq '.recent.add')
recent_del=$(echo "$code_json" | jq '.recent.del')
old_add=$(echo "$code_json" | jq '.old.add')
old_del=$(echo "$code_json" | jq '.old.del')
read r_pct_add r_pct_del < <(calc_percent "$recent_add" "$recent_del")
read o_pct_add o_pct_del < <(calc_percent "$old_add" "$old_del")

provider_label="$PROVIDER"
repo_label=""
cycle_time="null"
review_time="null"
pickup_time="null"
deploy_freq="null"
deploy_time="null"
mttr="null"
cfr="null"

case "$PROVIDER" in
  github)
    have gh || die "Para provider=github, instale/configure 'gh'."
    repo_label="$GH_REPO"; [[ -z "$repo_label" ]] && repo_label="$(detect_github_repo)"
    [[ -z "$repo_label" ]] && die "Informe --repo owner/name para GitHub."
    cycle_time=$(cycle_time_avg_hours_github "$repo_label")
    review_time=$(review_time_avg_hours_github "$repo_label")
    pickup_time=$(pickup_time_avg_hours_github "$repo_label")
    deploy_freq=$(deployment_frequency_github "$repo_label")
    deploy_time=$(deploy_time_avg_hours_github "$repo_label")
    mttr=$(mttr_avg_hours_github "$repo_label")
    cfr=$(cfr_percent_github "$repo_label")
    ;;
  azure)
    have az || die "Para provider=azure, instale/configure 'az' + azure-devops."
    [[ -z "$AZ_ORG" || -z "$AZ_PROJECT" || -z "$AZ_REPO_NAME" ]] && die "Azure requer --org --project --repo."
    repo_label="$AZ_REPO_NAME"
    cycle_time=$(cycle_time_avg_hours_azure)
    review_time=$(review_time_avg_hours_azure)
    pickup_time=$(pickup_time_avg_hours_azure)
    deploy_freq=$(deployment_frequency_azure)
    deploy_time=$(deploy_time_avg_hours_azure)
    mttr=$(mttr_avg_hours_azure)
    cfr=$(cfr_percent_azure)
    ;;
  bitbucket)
    : "${BB_WORKSPACE:?Use --workspace}"
    : "${BB_REPO_SLUG:?Use --repo <repo-slug>}"
    repo_label="$BB_WORKSPACE/$BB_REPO_SLUG"
    cycle_time=$(cycle_time_avg_hours_bitbucket)
    review_time=$(review_time_avg_hours_bitbucket)
    pickup_time=$(pickup_time_avg_hours_bitbucket)
    deploy_freq=$(deployment_frequency_bitbucket)
    deploy_time=$(deploy_time_avg_hours_bitbucket)
    mttr=$(mttr_avg_hours_bitbucket)
    cfr=$(cfr_percent_bitbucket)
    ;;
  *)
    die "Provider inválido: $PROVIDER"
    ;;
esac

jq -n --arg since "$SINCE" --arg until "$UNTIL" --arg provider "$provider_label" --arg repo "$repo_label" \
  --argjson commitFrequency "$commit_freq" \
  --argjson codingTimeHours "$coding_time" \
  --argjson recentAdd "$recent_add" \
  --argjson recentDel "$recent_del" \
  --argjson oldAdd "$old_add" \
  --argjson oldDel "$old_del" \
  --arg rAddPct "$r_pct_add" --arg rDelPct "$r_pct_del" \
  --arg oAddPct "$o_pct_add" --arg oDelPct "$o_pct_del" \
  --argjson cycleTimeHoursAvg "$cycle_time" \
  --argjson reviewTimeHoursAvg "$review_time" \
  --argjson pickupTimeHoursAvg "$pickup_time" \
  --argjson deploymentFrequency "$deploy_freq" \
  --argjson deployTimeHoursAvg "$deploy_time" \
  --argjson mttrHoursAvg "$mttr" \
  --argjson cfrPercent "$cfr" \
'{
  provider: $provider,
  repo: $repo,
  period: { since: $since, until: $until },
  commitFrequency: $commitFrequency,
  codingTimeHours: $codingTimeHours,
  codeMetrics: {
    recent: { add: $recentAdd, del: $recentDel, percentNewCode: ($rAddPct|tonumber), percentDeletedCode: ($rDelPct|tonumber) },
    old:    { add: $oldAdd,   del: $oldDel,   percentNewCode: ($oAddPct|tonumber), percentDeletedCode: ($oDelPct|tonumber) }
  },
  cycleTimeHoursAvg: $cycleTimeHoursAvg,
  reviewTimeHoursAvg: $reviewTimeHoursAvg,
  pickupTimeHoursAvg: $pickupTimeHoursAvg,
  deploymentFrequency: $deploymentFrequency,
  deployTimeHoursAvg: $deployTimeHoursAvg,
  mttrHoursAvg: $mttrHoursAvg,
  cfrPercent: $cfrPercent
}'
