# 📖 Explicação Detalhada — `git_metrics_daily_unified.sh`

Este documento explica em detalhes o funcionamento do script **`git_metrics_daily_unified.sh`**, responsável por executar o coletor principal (`git_metrics_unified.sh`) diariamente e manter um histórico em **JSON** e **CSV** (inclusive por autor).

---

## 🎯 Objetivo

- Automatizar a coleta diária de métricas.  
- Salvar um **snapshot diário em JSON**.  
- Manter séries históricas em **CSV** para dashboards.  
- Suportar métricas por **repositório** e por **autor**.

---

## ⚙️ Dependências

- **Comuns**: `git`, `jq`  
- **GitHub**: `gh` autenticado (`gh auth login`)  
- **Azure DevOps**: `az` + extensão `azure-devops`  
- **Bitbucket**: `curl` + variáveis de ambiente `BB_USER` e `BB_APP_PASS`

---

## 🧱 Estrutura do Script

### Cabeçalho
```bash
#!/usr/bin/env bash
set -euo pipefail
```
- Falha imediata em caso de erro, variável indefinida ou pipeline quebrado.

### Funções auxiliares
- `have`: verifica se um comando existe.  
- `die`: imprime erro e sai.

### Variáveis principais
- `REPO_PATH`: caminho local do repositório.  
- `PROVIDER`: `github|azure|bitbucket`.  
- `SINCE` / `UNTIL`: período da coleta. Se não informados, assume **ontem → hoje** (UTC).  
- `WINDOW_DAYS`: janela para código “recent” vs “old” (default: 21).

---

## 📥 Argumentos

- **Comuns**: `--repo-path`, `--provider`, `--since`, `--until`, `--window-days`  
- **GitHub**: `--repo` ou `--gh-repo`  
- **Azure**: `--org`, `--project`, `--az-repo`, `--pipeline-ids`, `--use-releases`  
- **Bitbucket**: `--workspace`, `--repo` (slug)

Validação mínima:
```bash
[[ -z "$REPO_PATH" || -z "$PROVIDER" ]] && die "Informe --repo-path e --provider ..."
```

---

## 📅 Datas automáticas

```bash
DATE_BIN="date"; $DATE_BIN -u +"%Y-%m-%d" >/dev/null 2>&1 || DATE_BIN="gdate"
if [[ -z "$SINCE" || -z "$UNTIL" ]]; then
  YEST=$($DATE_BIN -u -d "yesterday" +"%Y-%m-%d")
  TODAY=$($DATE_BIN -u +"%Y-%m-%d")
  SINCE="${SINCE:-$YEST}"
  UNTIL="${UNTIL:-$TODAY}"
fi
```
- Usa `date -d` (GNU). Se não existir (ex.: macOS), tenta `gdate`.

---

## 🔎 Localização do coletor principal

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "$SCRIPT_DIR/git_metrics_unified.sh" ]]; then
  METRICS_SH="$SCRIPT_DIR/git_metrics_unified.sh"
elif have git_metrics_unified.sh; then
  METRICS_SH="$(command -v git_metrics_unified.sh)"
else
  die "git_metrics_unified.sh não encontrado."
fi
```

Procura o `git_metrics_unified.sh` no mesmo diretório ou no PATH.

---

## 📂 Preparação e saídas

```bash
pushd "$REPO_PATH" >/dev/null
git fetch --all -p || true

OUT_DIR="$REPO_PATH/reports/$SINCE"
mkdir -p "$OUT_DIR"
JSON_OUT="$OUT_DIR/metrics_${PROVIDER}.json"
CSV_SERIES="$REPO_PATH/reports/metrics_daily_${PROVIDER}.csv"
```

- Um **JSON diário** (`reports/<YYYY-MM-DD>/metrics_<provider>.json`).  
- Um **CSV acumulado** (`reports/metrics_daily_<provider>.csv`).

---

## ⚙️ Execução do coletor

Monta os argumentos do `git_metrics_unified.sh` e o executa, salvando o JSON no dia.

```bash
ARGS=( --provider "$PROVIDER" --since "$SINCE" --until "$UNTIL" --window-days "$WINDOW_DAYS" )
...
"$METRICS_SH" "${ARGS[@]}" > "$JSON_OUT"
```

---

## 📝 Série CSV (geral)

Se for o primeiro dia, cria o cabeçalho do CSV.  
Depois, extrai os campos relevantes do JSON e acrescenta uma linha.

```bash
jq -r '[ .period.since, .repo, .commitFrequency, ... , .cfrPercent ] | @csv' "$JSON_OUT" >> "$CSV_SERIES"
```

---

## 👥 Série CSV por autor (opcional)

Se o script `git_metrics_by_author.sh` estiver disponível, roda também a coleta **por autor**, gerando/atualizando `metrics_daily_<provider>_by_author.csv`.

---

## ✅ Mensagens finais

```bash
echo "OK: JSON em $JSON_OUT"
echo "OK: Série CSV em $CSV_SERIES"
```

Feedback rápido da execução.

---

## 🚀 Exemplos de Uso

### GitHub
```bash
./git_metrics_daily_unified.sh   --repo-path "/srv/repos/minha-app"   --provider github   --repo "owner/minha-app"
```

### Azure DevOps
```bash
./git_metrics_daily_unified.sh   --repo-path "/srv/repos/minha-app"   --provider azure   --org "https://dev.azure.com/minha-org"   --project "MeuProjeto"   --az-repo "MinhaRepo"   --pipeline-ids "12 34"
```

### Bitbucket
```bash
export BB_USER="meu-user"
export BB_APP_PASS="meu-app-pass"
./git_metrics_daily_unified.sh   --repo-path "/srv/repos/minha-app"   --provider bitbucket   --workspace "minha-workspace"   --repo "repo-slug"
```

---

## ⏰ Execução Automática (cron)

Exemplo: rodar todos os dias às 02h15 UTC:

```cron
15 2 * * * /opt/metrics/git_metrics_daily_unified.sh   --repo-path "/srv/repos/minha-app"   --provider github   --repo "owner/minha-app"   >> /var/log/metrics_daily.log 2>&1
```

---

## ⚠️ Atenção

- **GNU date:** no macOS, instale `coreutils` (`brew install coreutils`).  
- **Permissões:** scripts precisam de `chmod +x`.  
- **Autenticação:**  
  - GitHub: `gh auth login`  
  - Azure: `az login` + `az extension add -n azure-devops`  
  - Bitbucket: exportar `BB_USER` e `BB_APP_PASS` no ambiente do cron.

---

✍️ Autor: Nelson Abu  
📅 Última atualização: 2025
