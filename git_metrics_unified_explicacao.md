# 📖 Explicação Detalhada — `git_metrics_unified.sh`

Este documento explica em detalhes o funcionamento do script **`git_metrics_unified.sh`**, que coleta métricas de engenharia a partir de repositórios **Git** e provedores de hospedagem (**GitHub**, **Azure DevOps**, **Bitbucket**).

---

## 🎯 Objetivo

- Extrair métricas de produtividade e qualidade baseadas em commits, pull requests, pipelines e releases.  
- Gerar uma saída **JSON padronizada** para ser consumida por dashboards (ex.: Grafana).  
- Permitir múltiplos provedores com **um único script**.

---

## ⚙️ Dependências

- **Comuns**: `git`, `jq`
- **GitHub**: `gh` (GitHub CLI) autenticado com `gh auth login`
- **Azure DevOps**: `az` (Azure CLI) + extensão `azure-devops`
- **Bitbucket**: `curl` + variáveis de ambiente `BB_USER` e `BB_APP_PASS` (App Password)

---

## 🧱 Estrutura do Script

### Cabeçalho e Configuração
```bash
#!/usr/bin/env bash
set -euo pipefail
```
- **`set -euo pipefail`**: falha rápida em caso de erro, variável indefinida ou pipeline quebrado.

### Funções utilitárias
- `have <cmd>`: verifica se um comando existe.  
- `die <msg>`: imprime erro e sai.  
- `iso_today` / `iso_days_ago`: datas padrão em UTC.  
- `date_diff_hours`: diferença em horas entre duas datas ISO.  
- `calc_percent`: calcula percentuais de adições/remoções de código.

### Argumentos e Defaults
- `--provider`: **obrigatório** (`github|azure|bitbucket`).  
- `--since` / `--until`: período da análise. Default = últimos 30 dias.  
- `--window-days`: separa código **recent** vs **old** (default 21).  
- Parâmetros específicos por provedor:  
  - GitHub: `--repo owner/name`  
  - Azure: `--org`, `--project`, `--repo`, `--pipeline-ids`, `--use-releases`  
  - Bitbucket: `--workspace`, `--repo`

---

## 📊 Métricas apenas Git

1. **Commit Frequency**  
Conta commits no período:
```bash
git rev-list --count --since="$SINCE" --until="$UNTIL" HEAD
```

2. **Coding Time (horas)**  
Diferença entre o primeiro e o último commit no período.

3. **Code Metrics (recent vs old)**  
Conta `add/del` de linhas recentes (últimos N dias) e antigas.

---

## 🐙 GitHub Helpers

- `gh_list_merged_prs`: lista PRs merged no período.  
- `gh_pr_earliest_commit_iso`: pega o commit mais antigo do PR.  
- `gh_list_releases_json`: releases para medir **deploy time**.

### Métricas no GitHub
- **Cycle Time**: earliest commit → mergedAt  
- **Review Time**: updatedAt → mergedAt  
- **Pickup Time**: createdAt → updatedAt  
- **Deployment Frequency**: número de PRs merged  
- **Deploy Time**: mergedAt → primeira release  
- **MTTR**: PRs com labels `bug|fix`  
- **CFR**: PRs com labels `failure|rollback`

---

## 🔷 Azure DevOps Helpers

- `az_list_completed_prs_json`: lista PRs concluídos.  
- `az_pr_earliest_commit_iso`: commit mais antigo do PR.  
- `az_list_releases_json` ou `az_list_pipeline_runs_after_iso`: releases ou pipelines para medir deploy.

### Métricas no Azure
- **Cycle Time**: creationDate → closedDate  
- **Review Time**: last commit → closedDate  
- **Pickup Time**: creationDate → primeiro update  
- **Deployment Frequency**: nº de PRs concluídos  
- **Deploy Time**: closedDate → release/pipeline  
- **MTTR**: PRs com labels `bug|fix`  
- **CFR**: PRs com labels `failure|rollback`

---

## 🪣 Bitbucket Helpers

- `bb_list_prs_merged_json`: lista PRs merged (até 4 páginas).  
- `bb_list_pipelines_json`: lista pipelines recentes.  

### Métricas no Bitbucket
- **Cycle Time**: created_on → updated_on  
- **Review Time**: updated_on → merged (usa updated_on como proxy)  
- **Pickup Time**: created_on → updated_on  
- **Deployment Frequency**: nº de PRs merged  
- **Deploy Time**: merged → pipeline completado  
- **MTTR**: PRs com título contendo `fix|bug`  
- **CFR**: PRs com título contendo `rollback|revert|failure`

---

## 📦 Saída JSON

Exemplo de schema emitido pelo script:

```json
{
  "provider": "github",
  "repo": "owner/repo",
  "period": { "since": "2025-01-01", "until": "2025-01-31" },
  "commitFrequency": 42,
  "codingTimeHours": 78.5,
  "codeMetrics": {
    "recent": { "add": 1234, "del": 567, "percentNewCode": 68.3, "percentDeletedCode": 31.7 },
    "old":    { "add": 4321, "del": 765, "percentNewCode": 52.1, "percentDeletedCode": 47.9 }
  },
  "cycleTimeHoursAvg": 36.2,
  "reviewTimeHoursAvg": 12.5,
  "pickupTimeHoursAvg": 6.1,
  "deploymentFrequency": 5,
  "deployTimeHoursAvg": 4.7,
  "mttrHoursAvg": 22.1,
  "cfrPercent": 10.5
}
```

---

## 🚀 Exemplos de uso

### GitHub
```bash
./git_metrics_unified.sh --provider github --repo "owner/my-repo"   --since "2025-01-01" --until "2025-01-31"
```

### Azure DevOps
```bash
./git_metrics_unified.sh --provider azure   --org "https://dev.azure.com/minha-org" --project "MeuProjeto" --repo "MeuRepo"   --pipeline-ids "12 34" --since "2025-01-01" --until "2025-01-31"
```

### Bitbucket
```bash
export BB_USER="meu-usuario"
export BB_APP_PASS="app-password"
./git_metrics_unified.sh --provider bitbucket   --workspace "minha-workspace" --repo "repo-slug"   --since "2025-01-01" --until "2025-01-31"
```

---

## ⚠️ Pontos de Atenção

- **GNU date:** no macOS use `gdate` (coreutils).  
- **Labels coerentes:** essenciais para MTTR e CFR.  
- **Paginação Bitbucket:** ajustável (atualmente até 4 páginas).  
- **Performance:** APIs podem ser lentas para períodos longos.  
- **Personalização:** regex de CFR/MTTR e lógica de deploy podem ser adaptadas.

---

✍️ Autor: Nelson Abu  
📅 Última atualização: 2025
