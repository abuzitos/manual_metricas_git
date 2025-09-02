# 📖 Explicação Detalhada — `git_metrics_by_author.sh`

Este documento explica em detalhes o funcionamento do script **`git_metrics_by_author.sh`**, responsável por gerar métricas **por autor** a partir de repositórios **Git** e provedores (GitHub | Azure DevOps | Bitbucket).

---

## 🎯 Objetivo

- Calcular métricas **por autor** (commits, tempo de codificação, linhas adicionadas/removidas).  
- Calcular métricas de **pull requests por autor** (cycle/review/pickup time, deployment frequency, MTTR, CFR).  
- Salvar em **CSV** (modo histórico, com `--csv-out`) ou imprimir **JSON** por autor (modo isolado).

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

### Funções auxiliares
- `die`, `have`: erro e checagem de binários.  
- `iso_today`, `iso_days_ago`: datas padrão.  
- `date_diff_hours`: diferença em horas entre duas datas ISO.  
- `calc_percent`: calcula percentuais de código adicionado/removido.

### Variáveis principais
- `PROVIDER`: **obrigatório** (`github|azure|bitbucket`).  
- `REPO_PATH`: **obrigatório** (pasta local do repo).  
- `SINCE`, `UNTIL`: período analisado (default: últimos 30 dias até hoje).  
- `WINDOW_DAYS`: janela para separar código “recent” vs “old” (default: 21).  
- `CSV_OUT`: caminho do CSV de saída (opcional).

---

## 👤 Descoberta de autores

Lista autores (nome|email) que comitaram no período:
```bash
git log --since="$SINCE" --until="$UNTIL" --format='%an|%ae|%ci' ...
```
Resultado vira JSON com `{ "author": "Nome|email" }`.

Se não houver commits:
- Se `--csv-out` foi passado, escreve só o cabeçalho do CSV.  
- Encerra execução.

---

## 📊 Métricas Git por autor

- **Commits**: `git log --author=... | wc -l`  
- **Coding time**: 1º commit → último commit do autor no período.  
- **Code metrics recent/old**: soma adds/dels do autor, separando por cutoff (`UNTIL - WINDOW_DAYS`).  
- **Percentuais**: calculados com `calc_percent`.

---

## 🔄 PRs por autor

### GitHub
- Busca todos PRs merged do período (`gh pr list`).  
- Filtra por `author.login`.  
- Métricas:  
  - `deploy_freq` = nº PRs do autor  
  - `cycle` = mergedAt - createdAt  
  - `review` = mergedAt - (updatedAt || createdAt)  
  - `pickup` = updatedAt - createdAt  
  - `mttr` = média mergedAt - createdAt (labels bug|fix)  
  - `cfr` = % PRs com labels failure|rollback

### Azure DevOps
- Busca PRs completed (`az repos pr list`).  
- Filtra por `createdBy.displayName`.  
- Métricas: iguais ao GitHub, mas usando `creationDate`, `closedDate`, `lastMergeSourceCommit.date`.

### Bitbucket
- Busca PRs merged via REST API.  
- Filtra por e-mail em `author.raw`.  
- Métricas:  
  - `cycle/review/pickup` baseados em `created_on`, `updated_on`  
  - `mttr`: títulos com regex `fix|bug`  
  - `cfr`: títulos com regex `rollback|revert|failure`

---

## 📦 Saída

### CSV
Cabeçalho:
```csv
date,repo,author,commitFrequency,codingTimeHours,code_recent_add,code_recent_del,...,cfrPercent
```

Cada autor vira uma linha com suas métricas.

### JSON
Exemplo por autor:
```json
{
  "date": "2025-01-01",
  "repo": "owner/repo",
  "author": "Alice|alice@example.com",
  "commitFrequency": 10,
  "codingTimeHours": 12.5,
  "codeMetrics": {
    "recent": { "add": 120, "del": 30, "percentNewCode": 80.0, "percentDeletedCode": 20.0 },
    "old":    { "add": 400, "del": 150, "percentNewCode": 72.7, "percentDeletedCode": 27.3 }
  },
  "cycleTimeHoursAvg": 35.0,
  "reviewTimeHoursAvg": 12.0,
  "pickupTimeHoursAvg": 5.0,
  "deploymentFrequency": 3,
  "deployTimeHoursAvg": 0.0,
  "mttrHoursAvg": 24.0,
  "cfrPercent": 10.0
}
```

---

## 🚀 Exemplos de Uso

### GitHub (CSV por autor)
```bash
./git_metrics_by_author.sh   --provider github   --repo "owner/name"   --repo-path "/repos/name"   --since 2025-01-01 --until 2025-01-31   --csv-out "/repos/name/reports/metrics_daily_github_by_author.csv"
```

### Azure DevOps (CSV por autor)
```bash
./git_metrics_by_author.sh   --provider azure   --org "https://dev.azure.com/minha-org"   --project "MeuProjeto"   --repo "MinhaRepo"   --repo-path "/repos/minha-repo"   --since 2025-01-01 --until 2025-01-31   --csv-out "/repos/minha-repo/reports/metrics_daily_azure_by_author.csv"
```

### Bitbucket (CSV por autor)
```bash
export BB_USER="meu-user"
export BB_APP_PASS="meu-app-pass"
./git_metrics_by_author.sh   --provider bitbucket   --workspace "minha-workspace"   --repo "repo-slug"   --repo-path "/repos/repo-slug"   --since 2025-01-01 --until 2025-01-31   --csv-out "/repos/repo-slug/reports/metrics_daily_bitbucket_by_author.csv"
```

---

## ⚠️ Pontos de Atenção

- **GNU date**: no macOS, use `gdate` (coreutils).  
- **Labels coerentes**: essenciais para métricas MTTR e CFR (GitHub/Azure).  
- **Regex no Bitbucket**: edite conforme seus padrões de PR.  
- **Volume de PRs**: ajuste `--limit` ou paginação se necessário.  
- **Mapeamento login/email**: GitHub usa login, não e-mail; ajuste se necessário.

---

✍️ Autor: Nelson Abu  
📅 Última atualização: 2025
