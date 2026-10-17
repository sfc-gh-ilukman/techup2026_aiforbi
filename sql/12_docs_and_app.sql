-- =============================================================================
-- 12_docs_and_app.sql — business documents and the Streamlit app, on stages
--
-- Cortex Sense reads files from stages, so everything it should learn from is
-- uploaded here:
--   @{{DB}}.RAW.DOCS                     5 business process documents
--   @{{DB}}.CORTEX_SENSE.SENSE_SOURCES   analyst query library (reviewed SQL)
--   @{{DB}}.APPS.STREAMLIT_SRC           Streamlit app source (stage-backed)
-- The Supplier Risk Score formula exists only in the app code. That is the point.
-- Paths point at the rendered copies in .build/ (created by scripts/lab.py).
-- =============================================================================

USE ROLE {{ROLE}};
USE WAREHOUSE {{WH}};

CREATE STAGE IF NOT EXISTS {{DB}}.CORTEX_SENSE.SENSE_SOURCES
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Extra Cortex Sense sources: reviewed analyst query library';

PUT 'file://{{BUILD_DIR}}/docs/supplier_management_process.md' @{{DB}}.RAW.DOCS AUTO_COMPRESS = FALSE OVERWRITE = TRUE;
PUT 'file://{{BUILD_DIR}}/docs/procurement_approval_policy.md' @{{DB}}.RAW.DOCS AUTO_COMPRESS = FALSE OVERWRITE = TRUE;
PUT 'file://{{BUILD_DIR}}/docs/contract_renewal_process.md' @{{DB}}.RAW.DOCS AUTO_COMPRESS = FALSE OVERWRITE = TRUE;
PUT 'file://{{BUILD_DIR}}/docs/budget_governance.md' @{{DB}}.RAW.DOCS AUTO_COMPRESS = FALSE OVERWRITE = TRUE;
PUT 'file://{{BUILD_DIR}}/docs/glossary.md' @{{DB}}.RAW.DOCS AUTO_COMPRESS = FALSE OVERWRITE = TRUE;
PUT 'file://{{BUILD_DIR}}/docs/analyst_query_library.md' @{{DB}}.CORTEX_SENSE.SENSE_SOURCES AUTO_COMPRESS = FALSE OVERWRITE = TRUE;

PUT 'file://{{BUILD_DIR}}/apps/peakfit_procurement_insights/streamlit_app.py' @{{DB}}.APPS.STREAMLIT_SRC/peakfit_procurement_insights AUTO_COMPRESS = FALSE OVERWRITE = TRUE;
PUT 'file://{{BUILD_DIR}}/apps/peakfit_procurement_insights/environment.yml' @{{DB}}.APPS.STREAMLIT_SRC/peakfit_procurement_insights AUTO_COMPRESS = FALSE OVERWRITE = TRUE;

ALTER STAGE {{DB}}.RAW.DOCS REFRESH;
ALTER STAGE {{DB}}.CORTEX_SENSE.SENSE_SOURCES REFRESH;
ALTER STAGE {{DB}}.APPS.STREAMLIT_SRC REFRESH;

-- Warehouse runtime: no compute pool or external access integration needed.
-- RUNTIME_NAME must be explicit: since the 2026_06 behavior change bundle a
-- CREATE STREAMLIT without it defaults to the container runtime.
CREATE OR REPLACE STREAMLIT {{DB}}.APPS.PEAKFIT_PROCUREMENT_INSIGHTS
  FROM '@{{DB}}.APPS.STREAMLIT_SRC/peakfit_procurement_insights'
  MAIN_FILE = 'streamlit_app.py'
  QUERY_WAREHOUSE = {{WH}}
  RUNTIME_NAME = 'SYSTEM$WAREHOUSE_RUNTIME'
  TITLE = 'PeakFit Procurement Insights'
  COMMENT = 'PeakFit procurement dashboard: spend overview, budget tracker, supplier scorecard with Supplier Risk Score.';

ALTER STREAMLIT {{DB}}.APPS.PEAKFIT_PROCUREMENT_INSIGHTS ADD LIVE VERSION FROM LAST;

SELECT 'RAW.DOCS' AS STAGE, COUNT(*) AS FILES FROM DIRECTORY(@{{DB}}.RAW.DOCS)
UNION ALL SELECT 'CORTEX_SENSE.SENSE_SOURCES', COUNT(*) FROM DIRECTORY(@{{DB}}.CORTEX_SENSE.SENSE_SOURCES)
UNION ALL SELECT 'APPS.STREAMLIT_SRC', COUNT(*) FROM DIRECTORY(@{{DB}}.APPS.STREAMLIT_SRC);
