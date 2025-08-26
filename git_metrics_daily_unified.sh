#!/usr/bin/env bash
set -euo pipefail

# git_metrics_daily_unified.sh — Executa git_metrics_unified.sh diariamente (cron/systemd) e mantém JSON+CSV.
have() { command -v "$1" >/dev/null 2>&1; }
die() { echo "Erro: $*" >&2; exit 1; }

REPO_PATH=""
PROVIDER=""
SINCE=""
UNTIL=""
WINDOW_DAYS=21

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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-path) REPO_PATH="$2"; shift 2;;
    --provider) PROVIDER="$2"; shift 2;;
    --since) SINCE="$2"; shift 2;;
    --until) UNTIL="$2"; shift 2;;
    --window-days) WINDOW_DAYS="$2"; shift 2;;

    --repo) 
      if [[ "${PROVIDER:-}" == "azure" ]]; then AZ_REPO_NAME="$2";
      elif [[ "${PROVIDER:-}" == "bitbucket" ]]; then BB_REPO_SLUG="$2";
      else GH_REPO="$2"; fi
      shift 2;;
    --gh-repo) GH_REPO="$2"; shift 2;;
    --org) AZ_ORG="$2"; shift 2;;
    --project) AZ_PROJECT="$2"; shift 2;;
    --az-repo) AZ_REPO_NAME="$2"; shift 2;;
    --pipeline-ids) AZ_PIPELINE_IDS="$2"; shift 2;;
    --use-releases) AZ_USE_RELEASES=true; shift 1;;
    --workspace) BB_WORKSPACE="$2"; shift 2;;
    *) die "Parâmetro desconhecido: $1";;
  esac
done

[[ -z "$REPO_PATH" || -z "$PROVIDER" ]] && die "Informe --repo-path e --provider github|azure|bitbucket."

DATE_BIN="date"; $DATE_BIN -u +"%Y-%m-%d" >/dev/null 2>&1 || DATE_BIN="gdate"
if [[ -z "$SINCE" || -z "$UNTIL" ]]; then
  YEST=$($DATE_BIN -u -d "yesterday" +"%Y-%m-%d")
  TODAY=$($DATE_BIN -u +"%Y-%m-%d")
  SINCE="${SINCE:-$YEST}"
  UNTIL="${UNTIL:-$TODAY}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "$SCRIPT_DIR/git_metrics_unified.sh" ]]; then
  METRICS_SH="$SCRIPT_DIR/git_metrics_unified.sh"
elif have git_metrics_unified.sh; then
  METRICS_SH="$(command -v git_metrics_unified.sh)"
else
  die "git_metrics_unified.sh não encontrado."
fi

pushd "$REPO_PATH" >/dev/null
git fetch --all -p || true

OUT_DIR="$REPO_PATH/reports/$SINCE"
mkdir -p "$OUT_DIR"
JSON_OUT="$OUT_DIR/metrics_${PROVIDER}.json"
CSV_SERIES="$REPO_PATH/reports/metrics_daily_${PROVIDER}.csv"

ARGS=( --provider "$PROVIDER" --since "$SINCE" --until "$UNTIL" --window-days "$WINDOW_DAYS" )
case "$PROVIDER" in
  github)
    [[ -n "$GH_REPO" ]] && ARGS+=( --repo "$GH_REPO" )
    ;;
  azure)
    [[ -z "$AZ_ORG" || -z "$AZ_PROJECT" || -z "$AZ_REPO_NAME" ]] && die "Azure requer --org --project --repo."
    ARGS+=( --org "$AZ_ORG" --project "$AZ_PROJECT" --repo "$AZ_REPO_NAME" )
    [[ -n "$AZ_PIPELINE_IDS" ]] && ARGS+=( --pipeline-ids "$AZ_PIPELINE_IDS" )
    $AZ_USE_RELEASES && ARGS+=( --use-releases )
    ;;
  bitbucket)
    [[ -z "$BB_WORKSPACE" || -z "$BB_REPO_SLUG" ]] && die "Bitbucket requer --workspace e --repo (slug)."
    ARGS+=( --workspace "$BB_WORKSPACE" --repo "$BB_REPO_SLUG" )
    ;;
  *)
    die "Provider inválido: $PROVIDER"
    ;;
esac

"$METRICS_SH" "${ARGS[@]}" > "$JSON_OUT"

if [[ ! -f "$CSV_SERIES" ]]; then
  echo "date,repo,commitFrequency,codingTimeHours,code_recent_add,code_recent_del,code_recent_percentNew,code_recent_percentDeleted,code_old_add,code_old_del,code_old_percentNew,code_old_percentDeleted,cycleTimeHoursAvg,reviewTimeHoursAvg,pickupTimeHoursAvg,deploymentFrequency,deployTimeHoursAvg,mttrHoursAvg,cfrPercent" > "$CSV_SERIES"
fi

jq -r '
  [
    .period.since,
    .repo,
    .commitFrequency,
    .codingTimeHours,
    .codeMetrics.recent.add,
    .codeMetrics.recent.del,
    .codeMetrics.recent.percentNewCode,
    .codeMetrics.recent.percentDeletedCode,
    .codeMetrics.old.add,
    .codeMetrics.old.del,
    .codeMetrics.old.percentNewCode,
    .codeMetrics.old.percentDeletedCode,
    .cycleTimeHoursAvg,
    .reviewTimeHoursAvg,
    .pickupTimeHoursAvg,
    .deploymentFrequency,
    .deployTimeHoursAvg,
    .mttrHoursAvg,
    .cfrPercent
  ] | @csv
' "$JSON_OUT" >> "$CSV_SERIES"

# --- Série por AUTOR (CSV adicional) ---
BY_AUTHOR_CSV="$REPO_PATH/reports/metrics_daily_${PROVIDER}_by_author.csv"
if [[ -x "$SCRIPT_DIR/git_metrics_by_author.sh" ]]; then
  case "$PROVIDER" in
    github)
      "$SCRIPT_DIR/git_metrics_by_author.sh" --provider github --repo-path "$REPO_PATH" --repo "${GH_REPO:-}" --since "$SINCE" --until "$UNTIL" --csv-out "$BY_AUTHOR_CSV"
      ;;
    azure)
      "$SCRIPT_DIR/git_metrics_by_author.sh" --provider azure --repo-path "$REPO_PATH" --org "$AZ_ORG" --project "$AZ_PROJECT" --repo "$AZ_REPO_NAME" --since "$SINCE" --until "$UNTIL" --csv-out "$BY_AUTHOR_CSV"
      ;;
    bitbucket)
      "$SCRIPT_DIR/git_metrics_by_author.sh" --provider bitbucket --repo-path "$REPO_PATH" --workspace "$BB_WORKSPACE" --repo "$BB_REPO_SLUG" --since "$SINCE" --until "$UNTIL" --csv-out "$BY_AUTHOR_CSV"
      ;;
  esac
fi

echo "OK: JSON em $JSON_OUT"
echo "OK: Série CSV em $CSV_SERIES"

popd >/dev/null
