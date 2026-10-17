-- =============================================================================
-- 30_agents.sql — the agent ladder for the demo (no context -> curated -> Sense)
--
--   PEAKFIT_NAKED_AGENT     no tools                         Q1 fails, Q2 fails
--   PEAKFIT_SV_AGENT        2 semantic views (Cortex Analyst) Q1 passes, Q2 fails
--   PEAKFIT_SENSE_AGENT     Cortex Sense (EnableCortexSense)  Q1 passes, Q2 passes
--   PEAKFIT_SV_SENSE_AGENT  semantic views + Cortex Sense     Q1 passes, Q2 passes
--
-- Q1: What was total approved spend in FY2026 by state?
-- Q2: Which at-risk suppliers have active contracts expiring in the next 90 days,
--     and what's their FY2026 spend?
--
-- The Sense agents only answer Q2 after phase B (`python3 scripts/lab.py sense`)
-- and once the context build has finished.
-- These are lab-owned objects, so CREATE OR REPLACE keeps the step re-runnable.
-- Spec notes (verified): EnableCortexSense adds cortex_sense + system_execute_sql;
-- declare only data_to_chart. With an Analyst tool present, arbitrary SQL needs
-- AgenticAnalystAllowArbitrarySQL (+ FallbackWarehouse).
-- =============================================================================

USE ROLE {{ROLE}};
USE WAREHOUSE {{WH}};
USE SCHEMA {{DB}}.ANALYTICS;

-- -----------------------------------------------------------------------------
-- 1. No tools
-- -----------------------------------------------------------------------------
CREATE OR REPLACE AGENT {{DB}}.ANALYTICS.{{AGENT_NAKED}}
  COMMENT = 'PeakFit demo, rung 1: no tools and no data access.'
  FROM SPECIFICATION $$
models:
  orchestration: auto
instructions:
  response: >-
    You are a procurement assistant for PeakFit Australia, a chain of 23 fitness
    centres. Answer concisely in Australian English.
$$;

-- -----------------------------------------------------------------------------
-- 2. Curated semantic views only
-- -----------------------------------------------------------------------------
CREATE OR REPLACE AGENT {{DB}}.ANALYTICS.{{AGENT_SV}}
  COMMENT = 'PeakFit demo, rung 2: the two curated semantic views via Cortex Analyst.'
  FROM SPECIFICATION $$
models:
  orchestration: auto
instructions:
  orchestration: >-
    Use procurement_analyst for purchase orders, spend, invoices, suppliers,
    buyers and profit centres. Use finance_workforce_analyst for budgets, budget
    variance, headcount, FTE and staff costs. All figures are as at 31 October
    2026 and financial years run July to June. If neither semantic view holds the
    data needed to answer, say so plainly instead of guessing.
  response: >-
    Answer concisely in Australian English. Lead with the number or list, then
    one line on how it was calculated. Format currency as AUD.
tools:
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: procurement_analyst
      description: Approved PO spend, purchase orders, invoices, suppliers, buyers, profit centres, spend codes and GL accounts.
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: finance_workforce_analyst
      description: Budgets vs actuals, budget variance, staff roster headcount and FTE, staff costs and spend per FTE.
  - tool_spec:
      type: data_to_chart
      name: data_to_chart
tool_resources:
  procurement_analyst:
    semantic_view: {{DB}}.ANALYTICS.PROCUREMENT_ANALYST
    execution_environment:
      type: warehouse
      warehouse: {{WH}}
  finance_workforce_analyst:
    semantic_view: {{DB}}.ANALYTICS.FINANCE_WORKFORCE_ANALYST
    execution_environment:
      type: warehouse
      warehouse: {{WH}}
$$;

-- -----------------------------------------------------------------------------
-- 3. Cortex Sense only (minimal spec)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE AGENT {{DB}}.ANALYTICS.{{AGENT_SENSE}}
  COMMENT = 'PeakFit demo, rung 3: grounded by the Cortex Sense context {{DB}}.CORTEX_SENSE.{{SENSE_CONTEXT}}.'
  FROM SPECIFICATION $$
models:
  orchestration: auto
experimental:
  EnableCortexSense: true
instructions:
  orchestration: >-
    Before writing any SQL, call cortex_sense once with the user's question
    verbatim and context_names ["{{DB}}.CORTEX_SENSE.{{SENSE_CONTEXT}}"]. Read every
    returned document: ontology_node documents define business terms, rules and
    formulas (they override anything you would assume from column names);
    table_entity documents give grain, columns and joins; qbe documents are
    reviewed SQL patterns to reuse. Apply every item in corrections. When the
    question uses a business term the context defines (for example at-risk,
    expiring soon, spend, material overrun), apply that definition in full,
    including every exclusion, instead of a literal reading of the words. Then answer
    with system_execute_sql against {{DB}} tables only. Evaluate "current",
    "active" and "next N days" as at 2026-10-31; financial years run July to June
    and "spend" means Approved purchase orders. If table_details omits a table,
    treat it as unknown and query it directly before concluding it is missing.
  response: >-
    Answer concisely in Australian English. Lead with the answer (number, list or
    table), then a short "How I worked it out" listing the business rules you
    applied and the source each came from (document, table or app), so the
    reader can trace every filter. Format currency as AUD.
tools:
  - tool_spec:
      type: data_to_chart
      name: data_to_chart
$$;

-- -----------------------------------------------------------------------------
-- 4. Semantic views + Cortex Sense (the realistic customer pattern)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE AGENT {{DB}}.ANALYTICS.{{AGENT_SV_SENSE}}
  COMMENT = 'PeakFit demo, rung 4: curated semantic views plus Cortex Sense for the long tail.'
  FROM SPECIFICATION $$
models:
  orchestration: auto
experimental:
  EnableCortexSense: true
  AgenticAnalystAllowArbitrarySQL: true
  FallbackWarehouse: {{WH}}
instructions:
  orchestration: >-
    Always call cortex_sense first with the user's question verbatim and
    context_names ["{{DB}}.CORTEX_SENSE.{{SENSE_CONTEXT}}"], and apply every business
    rule it returns. When the question uses a business term the context defines
    (for example at-risk, expiring soon, spend), apply that definition in full,
    including every exclusion, instead of a literal reading of the words. If the question is fully covered by a semantic view, answer
    with procurement_analyst or finance_workforce_analyst. If it needs tables or
    rules outside the semantic views (contracts, supplier assessments, incidents,
    assets, policy definitions, app-only metrics), write SQL with
    system_execute_sql against {{DB}} tables. Evaluate dates as at 2026-10-31;
    financial years run July to June and "spend" means Approved purchase orders.
  response: >-
    Answer concisely in Australian English. Lead with the answer, then a short
    "How I worked it out" naming the semantic view or the documents and tables
    used. Format currency as AUD.
tools:
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: procurement_analyst
      description: Approved PO spend, purchase orders, invoices, suppliers, buyers, profit centres, spend codes and GL accounts.
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: finance_workforce_analyst
      description: Budgets vs actuals, budget variance, staff roster headcount and FTE, staff costs and spend per FTE.
  - tool_spec:
      type: data_to_chart
      name: data_to_chart
tool_resources:
  procurement_analyst:
    semantic_view: {{DB}}.ANALYTICS.PROCUREMENT_ANALYST
    execution_environment:
      type: warehouse
      warehouse: {{WH}}
  finance_workforce_analyst:
    semantic_view: {{DB}}.ANALYTICS.FINANCE_WORKFORCE_ANALYST
    execution_environment:
      type: warehouse
      warehouse: {{WH}}
$$;

ALTER AGENT {{DB}}.ANALYTICS.{{AGENT_NAKED}}    SET PROFILE = '{"display_name": "PeakFit 1 - No tools"}';
ALTER AGENT {{DB}}.ANALYTICS.{{AGENT_SV}}       SET PROFILE = '{"display_name": "PeakFit 2 - Semantic views"}';
ALTER AGENT {{DB}}.ANALYTICS.{{AGENT_SENSE}}    SET PROFILE = '{"display_name": "PeakFit 3 - Cortex Sense"}';
ALTER AGENT {{DB}}.ANALYTICS.{{AGENT_SV_SENSE}} SET PROFILE = '{"display_name": "PeakFit 4 - Semantic views + Sense"}';

SHOW AGENTS IN SCHEMA {{DB}}.ANALYTICS;
