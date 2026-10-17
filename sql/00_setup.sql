-- =============================================================================
-- 00_setup.sql — {{DB}}: warehouse, database, schemas, stages
-- PeakFit Australia synthetic procurement dataset (see reference/DATA_MODEL.md)
-- Idempotent: safe to re-run.
-- =============================================================================

USE ROLE {{ROLE}};

CREATE WAREHOUSE IF NOT EXISTS {{WH}}
  WAREHOUSE_SIZE = XSMALL
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'PeakFit Cortex Sense lab (XS, auto-suspend 60s)';

CREATE DATABASE IF NOT EXISTS {{DB}}
  COMMENT = 'PeakFit Australia synthetic procurement dataset for the Cortex Sense AI for BI session. As-at 2026-10-31.';

-- PUBLIC exists by default; describe it
COMMENT ON SCHEMA {{DB}}.PUBLIC IS '15 base tables: procurement, finance, workforce and ancillary (uncurated) domains';

CREATE SCHEMA IF NOT EXISTS {{DB}}.ANALYTICS
  COMMENT = 'BUDGET_ACTUALS_VW, semantic views and Cortex Agents';
CREATE SCHEMA IF NOT EXISTS {{DB}}.RAW
  COMMENT = 'Business process documents (Markdown) on stage';
CREATE SCHEMA IF NOT EXISTS {{DB}}.APPS
  COMMENT = 'PeakFit Procurement Insights Streamlit app (stage-backed)';
CREATE SCHEMA IF NOT EXISTS {{DB}}.CORTEX_SENSE
  COMMENT = 'Cortex Sense home and source files';

CREATE STAGE IF NOT EXISTS {{DB}}.RAW.DOCS
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'PeakFit business process documents';
CREATE STAGE IF NOT EXISTS {{DB}}.APPS.STREAMLIT_SRC
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'PeakFit Procurement Insights app source';

-- -----------------------------------------------------------------------------
-- Build area. Generation, planted scenarios and validation run here, then the
-- finished tables are cloned into {{DB}}.PUBLIC (sql/07_promote.sql) and the
-- build database is dropped (sql/08_drop_build.sql).
-- This keeps generation/answer SQL out of the demo database's query history,
-- which Cortex Sense mines for query patterns.
-- -----------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS {{BUILD_DB}}
  COMMENT = 'Build area for {{DB}} synthetic data (generation, planted scenarios, validation)';
CREATE SCHEMA IF NOT EXISTS {{BUILD_DB}}.GEN
  COMMENT = 'Generation helper tables';
