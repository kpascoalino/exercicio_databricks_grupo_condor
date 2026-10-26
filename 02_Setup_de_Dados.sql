-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 🧱 Notebook 2 · Setup de Dados (Grupo Cóndor)
-- MAGIC ### Workshop Genie · Databricks Free Edition
-- MAGIC
-- MAGIC Este notebook cria **todo o dataset do workshop de forma determinística** (mesmo
-- MAGIC resultado toda vez), para que os módulos de **Genie Spaces** (Notebook 4) e **Genie One**
-- MAGIC (Notebook 5) sempre funcionem — mesmo que você não use o Genie Code para gerar os dados.
-- MAGIC
-- MAGIC > **Empresa fictícia — Grupo Cóndor:** conglomerado latino-americano com 3 unidades de
-- MAGIC > negócio: 🛒 **Cóndor Varejo** (lojas) · 💳 **Cóndor Pagos** (crédito ao consumo) ·
-- MAGIC > 🚚 **Cóndor Cargo** (logística). Dados 100% sintéticos.
-- MAGIC
-- MAGIC **O que este notebook cria em `workspace.grupo_condor`:**
-- MAGIC - Tabelas base: `dim_clientes`, `dim_lojas`, `fact_vendas`, `fact_creditos`, `fact_envios`
-- MAGIC - Camada **gold**: `gold_receita_diaria`, `gold_vendas_categoria`, `gold_carteira_creditos`, `gold_otif_envios`
-- MAGIC - Camada semântica (**Metric Views**): `metrics_grupo`, `metrics_carteira`, `metrics_envios`, `metrics_retail`
-- MAGIC
-- MAGIC ⏱️ Tempo: ~2 minutos. Use um **SQL Warehouse Serverless** (na Free Edition já vem um).
-- MAGIC
-- MAGIC ### ⚙️ Antes de rodar — catálogo
-- MAGIC Na **Free Edition** o catálogo padrão é **`workspace`** (já usado abaixo). Se a sua conta
-- MAGIC usar outro catálogo (ex.: `main`), faça um **Find & Replace** (`Ctrl/Cmd + H`) trocando
-- MAGIC `workspace.grupo_condor` pelo `seu_catalogo.grupo_condor` neste notebook. É a única mudança.
-- MAGIC
-- MAGIC ▶️ Para rodar tudo: **Run all** (Executar tudo) no topo.

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 1. Catálogo e schema

-- COMMAND ----------

USE CATALOG workspace;
CREATE SCHEMA IF NOT EXISTS workspace.grupo_condor;
USE SCHEMA grupo_condor;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 2. Tabelas base (dados sintéticos determinísticos)
-- MAGIC Geração baseada em `hash()` do id → reprodutível, sem aleatoriedade instável.

-- COMMAND ----------

-- 2.1 · Clientes (2.000)
CREATE OR REPLACE TABLE workspace.grupo_condor.dim_clientes AS
SELECT id+1 AS cliente_id,
  concat('Cliente ', lpad(cast(id+1 AS string),4,'0')) AS nome,
  element_at(array('MX','CO','PE','CL','AR','EC','BR'), pmod(hash(id,'pais'),7)+1) AS pais,
  concat('Cidade ', cast(pmod(hash(id,'cid'),40)+1 AS string)) AS cidade,
  CASE WHEN pmod(hash(id,'seg'),100) < 75 THEN 'B2C' ELSE 'B2B' END AS segmento,
  date_add(DATE'2023-01-01', pmod(hash(id,'alta'),1000)) AS data_cadastro
FROM range(2000);

-- COMMAND ----------

-- 2.2 · Lojas do Cóndor Varejo (120)
CREATE OR REPLACE TABLE workspace.grupo_condor.dim_lojas AS
SELECT id+1 AS loja_id,
  element_at(array('MX','CO','PE','CL','AR','EC','BR'), pmod(hash(id,'p'),7)+1) AS pais,
  concat('Cidade ', cast(pmod(hash(id,'c'),40)+1 AS string)) AS cidade,
  element_at(array('SUPER','EXPRESS','ONLINE'), pmod(hash(id,'f'),3)+1) AS formato
FROM range(120);

-- COMMAND ----------

-- 2.3 · Vendas do Cóndor Varejo (50.000) — inclui a anomalia de ELETRO no Chile em Q1-2026
CREATE OR REPLACE TABLE workspace.grupo_condor.fact_vendas AS
WITH b AS (
  SELECT id,
    id+1 AS venda_id,
    pmod(hash(id,'cli'),2000)+1 AS cliente_id,
    pmod(hash(id,'loj'),120)+1 AS loja_id,
    element_at(array('MX','CO','PE','CL','AR','EC','BR'), pmod(hash(id,'pais'),7)+1) AS pais,
    element_at(array('ELETRO','ALIMENTOS','CASA','MODA'), pmod(hash(id,'cat'),4)+1) AS categoria,
    element_at(array('LOJA','ONLINE'), pmod(hash(id,'can'),2)+1) AS canal,
    pmod(hash(id,'mes'),18) AS mes_idx
  FROM range(50000)
), s AS (
  SELECT *,
    -- anomalia: ~45% das vendas ELETRO/Chile de Q1-2026 "migram" para Q4-2025
    CASE WHEN categoria='ELETRO' AND pais='CL' AND mes_idx IN (12,13,14)
              AND pmod(hash(id,'shift'),100) < 45
         THEN element_at(array(9,10,11), pmod(hash(id,'q4'),3)+1)
         ELSE mes_idx END AS mes_final
  FROM b
)
SELECT venda_id, cliente_id, loja_id, pais, categoria, canal,
  date_add(add_months(DATE'2025-01-01', mes_final), pmod(hash(id,'day'),28)) AS data,
  round(CASE categoria WHEN 'ELETRO' THEN 800 WHEN 'ALIMENTOS' THEN 40
                       WHEN 'CASA' THEN 150 ELSE 90 END
        * (0.6 + pmod(hash(id,'amt'),800)/1000.0), 2) AS montante_usd
FROM s;

-- COMMAND ----------

-- 2.4 · Créditos do Cóndor Pagos (8.000)
CREATE OR REPLACE TABLE workspace.grupo_condor.fact_creditos AS
WITH b AS (
  SELECT id, id+1 AS credito_id,
    pmod(hash(id,'cli'),2000)+1 AS cliente_id,
    date_add(DATE'2025-01-01', pmod(hash(id,'orig'),545)) AS data_originacao,
    round(100 + pmod(hash(id,'m'),4900) + pmod(hash(id,'mc'),100)/100.0, 2) AS montante_usd,
    element_at(array(3,6,9,12,18,24), pmod(hash(id,'pz'),6)+1) AS prazo_meses,
    pmod(hash(id,'st'),100) AS st
  FROM range(8000)
)
SELECT credito_id, cliente_id, data_originacao, montante_usd, prazo_meses,
  CASE WHEN st < 15 THEN 'MOROSO' WHEN st < 40 THEN 'CANCELADO' ELSE 'ATIVO' END AS status,
  CASE WHEN st < 15 THEN 30 + pmod(hash(id,'atr'),91) ELSE pmod(hash(id,'atr2'),20) END AS dias_atraso
FROM b;

-- COMMAND ----------

-- 2.5 · Envios do Cóndor Cargo (30.000)
CREATE OR REPLACE TABLE workspace.grupo_condor.fact_envios AS
WITH b AS (
  SELECT id, id+1 AS envio_id,
    pmod(hash(id,'v'),50000)+1 AS venda_id,
    element_at(array('MX','CO','PE','CL','AR','EC','BR'), pmod(hash(id,'pd'),7)+1) AS pais_destino,
    date_add(DATE'2025-01-01', pmod(hash(id,'desp'),545)) AS data_despacho,
    pmod(hash(id,'e'),100) AS e,
    round(5 + pmod(hash(id,'cst'),45) + pmod(hash(id,'cc'),100)/100.0, 2) AS custo_envio_usd
  FROM range(30000)
), s AS (
  SELECT *,
    CASE WHEN (pais_destino='AR' AND e < 20) OR e < 8 THEN 'ATRASADO'
         WHEN e < 60 THEN 'ENTREGUE' ELSE 'EM_ROTA' END AS estado
  FROM b
)
SELECT envio_id, venda_id, pais_destino, data_despacho,
  CASE estado WHEN 'ENTREGUE' THEN date_add(data_despacho, 1+pmod(hash(id,'d1'),5))
              WHEN 'ATRASADO' THEN date_add(data_despacho, 6+pmod(hash(id,'d2'),10))
              ELSE NULL END AS data_entrega,
  estado, custo_envio_usd
FROM s;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 3. Camada Gold (tabelas de negócio)

-- COMMAND ----------

-- 3.1 · Receita diária por país e unidade de negócio
CREATE OR REPLACE TABLE workspace.grupo_condor.gold_receita_diaria AS
SELECT data, pais, 'VAREJO' AS unidade_negocio, round(sum(montante_usd),2) AS receita_usd
FROM workspace.grupo_condor.fact_vendas GROUP BY data, pais
UNION ALL
SELECT c.data_originacao AS data, cl.pais, 'PAGOS', round(sum(c.montante_usd*0.03),2)
FROM workspace.grupo_condor.fact_creditos c
JOIN workspace.grupo_condor.dim_clientes cl ON c.cliente_id=cl.cliente_id
WHERE c.status='ATIVO' GROUP BY c.data_originacao, cl.pais
UNION ALL
SELECT data_despacho AS data, pais_destino AS pais, 'CARGO', round(sum(custo_envio_usd),2)
FROM workspace.grupo_condor.fact_envios GROUP BY data_despacho, pais_destino;

-- COMMAND ----------

-- 3.2 · Vendas por categoria (dimensão de produto — essencial p/ a anomalia de ELETRO)
CREATE OR REPLACE TABLE workspace.grupo_condor.gold_vendas_categoria AS
SELECT data, pais, categoria, round(sum(montante_usd),2) AS receita_usd, count(*) AS num_vendas
FROM workspace.grupo_condor.fact_vendas GROUP BY data, pais, categoria;

-- COMMAND ----------

-- 3.3 · Carteira de créditos (snapshot com faixa de mora)
CREATE OR REPLACE TABLE workspace.grupo_condor.gold_carteira_creditos AS
SELECT credito_id, cliente_id, montante_usd AS saldo_estimado_usd, dias_atraso, status,
  CASE WHEN dias_atraso=0 THEN 'Em dia' WHEN dias_atraso<30 THEN '1-29'
       WHEN dias_atraso<60 THEN '30-59' WHEN dias_atraso<90 THEN '60-89'
       ELSE '90+' END AS faixa_mora
FROM workspace.grupo_condor.fact_creditos;

-- COMMAND ----------

-- 3.4 · OTIF de envios (entregas no prazo) por mês/país/estado
CREATE OR REPLACE TABLE workspace.grupo_condor.gold_otif_envios AS
SELECT date_format(data_despacho,'yyyy-MM') AS mes, pais_destino, estado,
  count(*) AS num_envios,
  sum(CASE WHEN data_entrega IS NOT NULL AND datediff(data_entrega,data_despacho)<=5 THEN 1 ELSE 0 END) AS entregas_no_prazo
FROM workspace.grupo_condor.fact_envios GROUP BY 1,2,3;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 4. Metric Views (camada semântica governada)
-- MAGIC As Metric Views definem **dimensões e métricas** uma única vez. O Genie Space (Notebook 4)
-- MAGIC usa **estas** como fonte — é o que garante respostas consistentes em linguagem natural.
-- MAGIC Consulta-se com a função `MEASURE(<medida>)`.

-- COMMAND ----------

-- 4.1 · metrics_grupo — receita por país, unidade de negócio e mês
CREATE OR REPLACE VIEW workspace.grupo_condor.metrics_grupo WITH METRICS
LANGUAGE YAML
AS $$
version: 0.1
source: workspace.grupo_condor.gold_receita_diaria
dimensions:
  - name: pais
    expr: pais
  - name: unidade_negocio
    expr: unidade_negocio
  - name: mes
    expr: date_format(data, 'yyyy-MM')
measures:
  - name: receita_usd
    expr: SUM(receita_usd)
$$;

-- COMMAND ----------

-- 4.2 · metrics_carteira — saldo e taxa de morosidade (dias_atraso >= 30)
CREATE OR REPLACE VIEW workspace.grupo_condor.metrics_carteira WITH METRICS
LANGUAGE YAML
AS $$
version: 0.1
source: workspace.grupo_condor.gold_carteira_creditos
dimensions:
  - name: faixa_mora
    expr: faixa_mora
  - name: status
    expr: status
measures:
  - name: saldo_total_usd
    expr: SUM(saldo_estimado_usd)
  - name: tasa_morosidade_pct
    expr: SUM(CASE WHEN dias_atraso >= 30 THEN saldo_estimado_usd ELSE 0 END) / SUM(saldo_estimado_usd) * 100
$$;

-- COMMAND ----------

-- 4.3 · metrics_envios — % de entregas no prazo (OTIF)
CREATE OR REPLACE VIEW workspace.grupo_condor.metrics_envios WITH METRICS
LANGUAGE YAML
AS $$
version: 0.1
source: workspace.grupo_condor.gold_otif_envios
dimensions:
  - name: mes
    expr: mes
  - name: pais_destino
    expr: pais_destino
  - name: estado
    expr: estado
measures:
  - name: otif_pct
    expr: SUM(entregas_no_prazo) / SUM(num_envios) * 100
$$;

-- COMMAND ----------

-- 4.4 · metrics_retail — receita e ticket médio por país, categoria e mês
CREATE OR REPLACE VIEW workspace.grupo_condor.metrics_retail WITH METRICS
LANGUAGE YAML
AS $$
version: 0.1
source: workspace.grupo_condor.gold_vendas_categoria
dimensions:
  - name: pais
    expr: pais
  - name: categoria
    expr: categoria
  - name: mes
    expr: date_format(data, 'yyyy-MM')
measures:
  - name: receita_usd
    expr: SUM(receita_usd)
  - name: ticket_medio_usd
    expr: SUM(receita_usd) / SUM(num_vendas)
$$;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 5. Validação (confirme que tudo ficou verde)

-- COMMAND ----------

-- 5.1 · Contagens esperadas: 2.000 / 120 / 50.000 / 8.000 / 30.000
SELECT 'clientes' AS tabela, count(*) AS linhas FROM workspace.grupo_condor.dim_clientes
UNION ALL SELECT 'lojas',    count(*) FROM workspace.grupo_condor.dim_lojas
UNION ALL SELECT 'vendas',   count(*) FROM workspace.grupo_condor.fact_vendas
UNION ALL SELECT 'creditos', count(*) FROM workspace.grupo_condor.fact_creditos
UNION ALL SELECT 'envios',   count(*) FROM workspace.grupo_condor.fact_envios
ORDER BY tabela;

-- COMMAND ----------

-- 5.2 · A anomalia: receita de ELETRO no Chile cai forte em Q1-2026 vs Q4-2025
--        (ticket médio ~estável → é queda de VOLUME, não de preço)
SELECT mes,
       round(MEASURE(receita_usd),0)      AS receita_usd,
       round(MEASURE(ticket_medio_usd),2) AS ticket_medio_usd
FROM workspace.grupo_condor.metrics_retail
WHERE categoria='ELETRO' AND pais='CL'
  AND mes IN ('2025-10','2025-11','2025-12','2026-01','2026-02','2026-03')
GROUP BY mes ORDER BY mes;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ✅ **Setup concluído.** Você deve ver ~120 mil/mês em ELETRO/CL no Q4-2025 caindo para
-- MAGIC ~45–58 mil/mês no Q1-2026, com ticket médio próximo de US$ 800 nos dois períodos.
-- MAGIC
-- MAGIC ➡️ **Próximo:** abra o **Notebook 3 · Genie Code** para aprender a construir/estender
-- MAGIC este mesmo modelo com prompts em linguagem natural — ou pule direto para o
-- MAGIC **Notebook 4 · Genie Spaces** para começar a fazer perguntas.