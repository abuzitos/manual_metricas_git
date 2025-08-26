# 📊 Guia de Dashboards Grafana

Este guia explica como importar e utilizar os dashboards Grafana preparados para visualizar as métricas coletadas pelos scripts.

---

## ✅ Pré-requisitos

- **Grafana** instalado no Ubuntu ou em container.
- Plugin **CSV Datasource** instalado:
```bash
sudo grafana-cli plugins install marcusolsson-csv-datasource
sudo systemctl restart grafana-server
```

- Arquivos CSV gerados pelos scripts:
  - `metrics_daily_<provider>.csv`
  - `metrics_daily_<provider>_by_author.csv`

---

## 📈 Dashboard Geral - `metrics_dashboard_grafana.json`

- Inclui métricas gerais por repositório:
  - **Cycle Time**
  - **Deployment Frequency**
  - **MTTR**
  - **CFR**
  - **Review Time**
  - **Pickup Time**
  - **Coding Time**
  - **Commit Frequency**
  - **Deploy Time**

### Importação
1. Vá em **Dashboards → Import → Upload JSON**.  
2. Selecione o arquivo [`metrics_dashboard_grafana.json`](metrics_dashboard_grafana.json).  
3. Configure a datasource CSV para apontar para `metrics_daily_<provider>.csv`.

---

## 👥 Dashboard por Repositório e Autor - `metrics_dashboard_by_author.json`

- Permite filtrar métricas por **repo** e **autor**.  
- Variáveis de filtro:
  - `csv_path` → caminho do CSV (`metrics_daily_<provider>_by_author.csv`)  
  - `repo` → regex para repositório (ex.: `org/repo` ou `.*`)  
  - `author` → regex para autor (ex.: `Maria` ou `.*`)  

### Importação
1. Vá em **Dashboards → Import → Upload JSON**.  
2. Selecione o arquivo [`metrics_dashboard_by_author.json`](metrics_dashboard_by_author.json).  
3. Configure a datasource CSV para apontar para `metrics_daily_<provider>_by_author.csv`.  

### Exemplo de CSV por autor
```csv
date,repo,author,commitFrequency,codingTimeHours,cycleTimeHoursAvg,reviewTimeHoursAvg,pickupTimeHoursAvg
2025-01-01,org/repo,Maria|maria@empresa.com,12,3.5,24.2,10.1,5.0
```

---

## 📷 Diagramas de Apoio

- Métricas DORA  
  ![Métricas DORA](diagram_dora.png)

- Fluxo Cron (coleta automática)  
  ![Fluxo Cron](diagram_cron.png)

---

## ℹ️ Observações Finais

- Os dashboards funcionam para **GitHub**, **Azure DevOps** e **Bitbucket**.  
- Basta apontar a variável `csv_path` para o CSV gerado pelo provedor correspondente.  
- É possível criar múltiplas datasources CSV para manter cada provedor separado.  

---

✍️ Autor: Nelson Abu  
📅 Última atualização: 2025
