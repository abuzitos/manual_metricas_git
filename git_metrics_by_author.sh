#!/usr/bin/env bash
set -euo pipefail

# git_metrics_by_author.sh — Gera métricas por AUTOR para GitHub | Azure DevOps | Bitbucket.
# Saída: CSV (append) OU JSON por autor.
# Uso típico (GitHub):
#   ./git_metrics_by_author.sh --provider github --repo "owner/name" --repo-path "/path/repo" --since 2025-01-01 --until 2025-01-31 \
#     --csv-out "/path/repo/reports/metrics_daily_github_by_author.csv"
#
# Requisitos: jq, git; (gh) para GitHub; (az + azure-devops) para Azure; (curl + BB_USER/BB_APP_PASS) para Bitbucket.

die() { echo "Erro: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

iso_today() { date -u +"%Y-%m-%d"; }
iso_days_ago() { local d="${1:-30}"; date -u -d "-$d days" +"%Y-%m-%d"; }

date_diff_hours() {
  local a="$1" b="$2"
  local ta tb
  ta=$(date -d "$a" +%s 2>/dev/null || true)
  tb=$(date -d "$b" +%s 2>/dev/null || true)
  [[ -z "$ta" || -z "$tb" ]] && { printf "0.00"; return; }
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

PROVIDER=""
REPO_PATH=""
SINCE="$(iso_days_ago 30)"
UNTIL="$(iso_today)"
WINDOW_DAYS=21
CSV_OUT=""

# GitHub
GH_REPO=""

# Azure
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
    --repo-path) REPO_PATH="$2"; shift 2;;
    --since) SINCE="$2"; shift 2;;
    --until) UNTIL="$2"; shift 2;;
    --window-days) WINDOW_DAYS="$2"; shift 2;;
    --csv-out) CSV_OUT="$2"; shift 2;;

    --repo) 
      if [[ "${PROVIDER:-}" == "azure" ]]; then AZ_REPO_NAME="$2";
      elif [[ "${PROVIDER:-}" == "bitbucket" ]]; then BB_REPO_SLUG="$2";
      else GH_REPO="$2"; fi
      shift 2;;
    --org) AZ_ORG="$2"; shift 2;;
    --project) AZ_PROJECT="$2"; shift 2;;
    --pipeline-ids) AZ_PIPELINE_IDS="$2"; shift 2;;
    --use-releases) AZ_USE_RELEASES=true; shift 1;;
    --workspace) BB_WORKSPACE="$2"; shift 2;;
    *) die "Parâmetro desconhecido: $1";;
  esac
done

[[ -z "$PROVIDER" || -z "$REPO_PATH" ]] && die "Informe --provider e --repo-path."

have git || die "git não encontrado."
have jq || die "jq não encontrado."

pushd "$REPO_PATH" >/dev/null

# --------- GIT (por autor) ---------
authors_json=$(git log --since="$SINCE" --until="$UNTIL" --format='%an|%ae|%ci' | awk -F'|' '{print $1"|"$2}' | sort -u | awk '{printf "{\"author\":\"%s\"}\n", $0}' | jq -s '.')
if [[ "$(echo "$authors_json" | jq 'length')" -eq 0 ]]; then
  if [[ -n "$CSV_OUT" && ! -f "$CSV_OUT" ]]; then
    echo "date,repo,author,commitFrequency,codingTimeHours,code_recent_add,code_recent_del,code_recent_percentNew,code_recent_percentDeleted,code_old_add,code_old_del,code_old_percentNew,code_old_percentDeleted,cycleTimeHoursAvg,reviewTimeHoursAvg,pickupTimeHoursAvg,deploymentFrequency,deployTimeHoursAvg,mttrHoursAvg,cfrPercent" > "$CSV_OUT"
  fi
  popd >/dev/null
  exit 0
fi

git_commit_count_by_author() {
  git log --since="$SINCE" --until="$UNTIL" --author="$1" --pretty=oneline | wc -l | awk '{printf "%d",$1}'
}
git_coding_time_by_author() {
  local first last
  first=$(git log --since="$SINCE" --until="$UNTIL" --author="$1" --pretty=format:%ci | tail -1 || true)
  last=$(git log --since="$SINCE" --until="$UNTIL" --author="$1" --pretty=format:%ci | head -1 || true)
  [[ -z "$first" || -z "$last" ]] && { echo "0.00"; return; }
  date_diff_hours "$first" "$last"
}
git_code_metrics_by_author() {
  local cutoff; cutoff=$(date -u -d "$UNTIL -$WINDOW_DAYS days" +"%Y-%m-%dT%H:%M:%SZ")
  git log --since="$SINCE" --until="$UNTIL" --author="$1" --numstat --pretty="---%H %cI" |
  awk -v cutoff="$cutoff" '
    BEGIN { ra=0; rd=0; oa=0; od=0; cur="" }
    /^---/ { cur=$2; next }
    NF==3 && $1 ~ /^[0-9-]+$/ && $2 ~ /^[0-9-]+$/ {
      add=$1; del=$2;
      if (add == "-") add=0; if (del == "-") del=0;
      if (cur >= cutoff) { ra+=add; rd+=del } else { oa+=add; od+=del }
    }
    END { printf("%d %d %d %d", ra, rd, oa, od) }'
}

# --------- PRs por autor ---------
gh_prs_by_author() {
  have gh || die "Requer gh."
  local repo="$1" author_login="$2"
  gh pr list --repo "$repo" --state merged --search "author:$author_login merged:>=$SINCE merged:<=$UNTIL" --limit 200 \
    --json number,createdAt,updatedAt,mergedAt,title,author,labels
}
az_prs_by_author() {
  have az || die "Requer az."
  az devops configure -d organization="$AZ_ORG" project="$AZ_PROJECT" >/dev/null 2>&1 || true
  az repos pr list --repository "$AZ_REPO_NAME" --status completed --output json \
  | jq --arg since "$SINCE" --arg until "$UNTIL" 'map(select(.closedDate != null and .closedDate >= ($since+"T00:00:00Z") and .closedDate <= ($until+"T23:59:59Z")))'
}
bb_auth() { : "${BB_USER:?Defina BB_USER}"; : "${BB_APP_PASS:?Defina BB_APP_PASS}"; }
bb_prs_merged() {
  bb_auth
  local url="$BB_API/repositories/$BB_WORKSPACE/$BB_REPO_SLUG/pullrequests?state=MERGED&pagelen=50"
  curl -s -u "$BB_USER:$BB_APP_PASS" "$url" | jq '.values'
}

repo_label=""
case "$PROVIDER" in
  github) repo_label="$GH_REPO"; [[ -z "$repo_label" ]] && repo_label=$(git remote get-url origin 2>/dev/null | sed -n 's#.*github.com[:/]\([^/]\+\)/\([^/.]\+\).*#\1/\2#p'); [[ -z "$repo_label" ]] && die "Informe --repo owner/name";;
  azure)  [[ -z "$AZ_ORG" || -z "$AZ_PROJECT" || -z "$AZ_REPO_NAME" ]] && die "Azure requer --org --project --repo"; repo_label="$AZ_REPO_NAME";;
  bitbucket) [[ -z "$BB_WORKSPACE" || -z "$BB_REPO_SLUG" ]] && die "Bitbucket requer --workspace e --repo"; repo_label="$BB_WORKSPACE/$BB_REPO_SLUG";;
  *) die "Provider inválido";;
esac

if [[ -n "$CSV_OUT" && ! -f "$CSV_OUT" ]]; then
  echo "date,repo,author,commitFrequency,codingTimeHours,code_recent_add,code_recent_del,code_recent_percentNew,code_recent_percentDeleted,code_old_add,code_old_del,code_old_percentNew,code_old_percentDeleted,cycleTimeHoursAvg,reviewTimeHoursAvg,pickupTimeHoursAvg,deploymentFrequency,deployTimeHoursAvg,mttrHoursAvg,cfrPercent" > "$CSV_OUT"
fi

gh_all_prs="[]"
az_all_prs="[]"
bb_all_prs="[]"
if [[ "$PROVIDER" == "github" ]]; then
  gh_all_prs=$(gh pr list --repo "$repo_label" --state merged --search "merged:>=$SINCE merged:<=$UNTIL" --limit 400 --json number,createdAt,updatedAt,mergedAt,title,author,labels)
elif [[ "$PROVIDER" == "azure" ]]; then
  az_all_prs=$(az_prs_by_author)
elif [[ "$PROVIDER" == "bitbucket" ]]; then
  bb_all_prs=$(bb_prs_merged)
fi

metric_prs_for_author() {
  local provider="$1" author="$2"
  case "$provider" in
    github)
      local login="${author##*|}"; login="${login%@*}"
      local prs=$(echo "$gh_all_prs" | jq --arg login "$login" '[ .[] | select(.author.login == $login) ]')
      local n=$(echo "$prs" | jq 'length'); [[ "$n" -eq 0 ]] && { echo "0 0.00 0.00 0.00 0.00 0.00"; return; }
      local deploy_freq="$n"
      local cycle=$(echo "$prs" | jq -r '[ .[] | select(.mergedAt != null and .createdAt != null) | (( .mergedAt | fromdateiso8601 ) - ( .createdAt | fromdateiso8601 )) / 3600 ] | add / length // 0' )
      local review=$(echo "$prs" | jq -r '[ .[] | select(.mergedAt != null) | (( .mergedAt | fromdateiso8601 ) - ( ( .updatedAt // .createdAt ) | fromdateiso8601 )) / 3600 ] | add / length // 0' )
      local pickup=$(echo "$prs" | jq -r '[ .[] | select(.updatedAt != null) | (( .updatedAt | fromdateiso8601 ) - ( .createdAt | fromdateiso8601 )) / 3600 ] | add / length // 0' )
      local mttr=$(echo "$prs" | jq -r '[ .[] | select(any(.labels[]?; .name=="bug" or .name=="fix")) | (( .mergedAt | fromdateiso8601 ) - ( .createdAt | fromdateiso8601 )) / 3600 ] | add / length // 0')
      local cfr=$(echo "$prs" | jq -r '[ .[] | select(any(.labels[]?; .name=="failure" or .name=="rollback")) ] | length as $f | ($f*100 / (length // 1 + 0.00001))' )
      echo "$deploy_freq $cycle $review $pickup $mttr $cfr"
      ;;
    azure)
      local name="${author%%|*}"
      local prs=$(echo "$az_all_prs" | jq --arg name "$name" '[ .[] | select(.createdBy.displayName == $name) ]')
      local n=$(echo "$prs" | jq 'length'); [[ "$n" -eq 0 ]] && { echo "0 0.00 0.00 0.00 0.00 0.00"; return; }
      local deploy_freq="$n"
      local cycle=$(echo "$prs" | jq -r '[ .[] | select(.closedDate != null and .creationDate != null) | (( .closedDate | fromdateiso8601 ) - ( .creationDate | fromdateiso8601 )) / 3600 ] | add / length // 0')
      local review=$(echo "$prs" | jq -r '[ .[] | select(.closedDate != null) | (( .closedDate | fromdateiso8601 ) - ( ( .lastMergeSourceCommit.committer.date // .creationDate ) | fromdateiso8601 )) / 3600 ] | add / length // 0')
      local pickup=$(echo "$prs" | jq -r '[ .[] | select(.lastMergeSourceCommit.committer.date != null) | (( .lastMergeSourceCommit.committer.date | fromdateiso8601 ) - ( .creationDate | fromdateiso8601 )) / 3600 ] | add / length // 0')
      local mttr=$(echo "$prs" | jq -r '[ .[] | select(any(.labels[]?.name; . == "bug" or . == "fix")) | (( .closedDate | fromdateiso8601 ) - ( .creationDate | fromdateiso8601 )) / 3600 ] | add / length // 0')
      local cfr=$(echo "$prs" | jq -r '[ .[] | select(any(.labels[]?.name; . == "failure" or . == "rollback")) ] | length as $f | ($f*100 / (length // 1 + 0.00001))')
      echo "$deploy_freq $cycle $review $pickup $mttr $cfr"
      ;;
    bitbucket)
      local email="${author##*|}"
      local prs=$(echo "$bb_all_prs" | jq --arg email "$email" '[ .[] | select(.author.raw | contains($email)) ]')
      local n=$(echo "$prs" | jq 'length'); [[ "$n" -eq 0 ]] && { echo "0 0.00 0.00 0.00 0.00 0.00"; return; }
      local deploy_freq="$n"
      local cycle=$(echo "$prs" | jq -r '[ .[] | (( .updated_on | fromdateiso8601 ) - ( .created_on | fromdateiso8601 )) / 3600 ] | add / length // 0')
      local review=$(echo "$prs" | jq -r '[ .[] | (( .updated_on | fromdateiso8601 ) - ( .created_on | fromdateiso8601 )) / 3600 ] | add / length // 0')
      local pickup=$(echo "$prs" | jq -r '[ .[] | (( .updated_on | fromdateiso8601 ) - ( .created_on | fromdateiso8601 )) / 3600 ] | add / length // 0')
      local mttr=$(echo "$prs" | jq -r '[ .[] | select(.title | test("(?i)\\bfix\\b|\\bbug\\b")) | (( .updated_on | fromdateiso8601 ) - ( .created_on | fromdateiso8601 )) / 3600 ] | add / length // 0')
      local cfr=$(echo "$prs" | jq -r '[ .[] | select(.title | test("(?i)rollback|revert|failure")) ] | length as $f | ($f*100 / (length // 1 + 0.00001))')
      echo "$deploy_freq $cycle $review $pickup $mttr $cfr"
      ;;
    *)
      echo "0 0.00 0.00 0.00 0.00 0.00"
      ;;
  esac
}

if [[ -n "$CSV_OUT" && ! -f "$CSV_OUT" ]]; then
  echo "date,repo,author,commitFrequency,codingTimeHours,code_recent_add,code_recent_del,code_recent_percentNew,code_recent_percentDeleted,code_old_add,code_old_del,code_old_percentNew,code_old_percentDeleted,cycleTimeHoursAvg,reviewTimeHoursAvg,pickupTimeHoursAvg,deploymentFrequency,deployTimeHoursAvg,mttrHoursAvg,cfrPercent" > "$CSV_OUT"
fi

repo_label="(repo)"
if [[ -d "$REPO_PATH/.git" ]]; then
  pushd "$REPO_PATH" >/dev/null
fi

while IFS= read -r item; do
  a_name=$(echo "$item" | jq -r '.author' | cut -d'|' -f1)
  a_email=$(echo "$item" | jq -r '.author' | cut -d'|' -f2)
  author_key="$a_name|$a_email"

  commits=$(git_commit_count_by_author "$a_email")
  coding=$(git_coding_time_by_author "$a_email")
  read r_add r_del o_add o_del < <(git_code_metrics_by_author "$a_email")
  read r_pct_add r_pct_del < <(calc_percent "$r_add" "$r_del")
  read o_pct_add o_pct_del < <(calc_percent "$o_add" "$o_del")

  read dfreq cycle review pickup mttr cfr < <(metric_prs_for_author "$PROVIDER" "$author_key")

  if [[ -n "$CSV_OUT" ]]; then
    printf "%s,%s,%s,%s,%s,%s,%s,%.2f,%.2f,%s,%s,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%0.2f\n" \
      "$SINCE" "$repo_label" "$author_key" \
      "$commits" "$coding" \
      "$r_add" "$r_del" "$r_pct_add" "$r_pct_del" \
      "$o_add" "$o_del" "$o_pct_add" "$o_pct_del" \
      "$cycle" "$review" "$pickup" "$dfreq" "0.00" "$mttr" "$cfr" >> "$CSV_OUT"
  else
    jq -n --arg date "$SINCE" --arg repo "$repo_label" --arg author "$author_key" \
      --argjson commitFrequency "$commits" --argjson codingTimeHours "$coding" \
      --argjson recentAdd "$r_add" --argjson recentDel "$r_del" \
      --argjson oldAdd "$o_add" --argjson oldDel "$o_del" \
      --arg rAddPct "$r_pct_add" --arg rDelPct "$r_pct_del" \
      --arg oAddPct "$o_pct_add" --arg oDelPct "$o_pct_del" \
      --argjson cycleTimeHoursAvg "$cycle" --argjson reviewTimeHoursAvg "$review" \
      --argjson pickupTimeHoursAvg "$pickup" --argjson deploymentFrequency "$dfreq" \
      --argjson deployTimeHoursAvg 0 \
      --argjson mttrHoursAvg "$mttr" --argjson cfrPercent "$cfr" \
      '{date:$date, repo:$repo, author:$author,
        commitFrequency:$commitFrequency, codingTimeHours:$codingTimeHours,
        codeMetrics:{ recent:{add:$recentAdd,del:$recentDel,percentNewCode:($rAddPct|tonumber),percentDeletedCode:($rDelPct|tonumber)},
                      old:{add:$oldAdd,del:$oldDel,percentNewCode:($oAddPct|tonumber),percentDeletedCode:($oDelPct|tonumber)}},
        cycleTimeHoursAvg:$cycleTimeHoursAvg, reviewTimeHoursAvg:$reviewTimeHoursAvg, pickupTimeHoursAvg:$pickupTimeHoursAvg,
        deploymentFrequency:$deploymentFrequency, deployTimeHoursAvg:$deployTimeHoursAvg, mttrHoursAvg:$mttrHoursAvg, cfrPercent:$cfrPercent }'
  fi
done < <(echo "$authors_json" | jq -c '.[]')

popd >/dev/null
