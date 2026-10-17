-- =============================================================================
-- 03_finance_workforce.sql — BUDGETS, STAFF_COSTS, STAFF_ROSTER (build area)
-- Depends on 02_procurement_facts.sql. BUDGET_ACTUALS_VW is created in
-- {{DB}}.ANALYTICS at promotion (sql/07_promote.sql); a copy is
-- created here for validation.
-- =============================================================================

USE ROLE {{ROLE}};
USE WAREHOUSE {{WH}};
USE SCHEMA {{BUILD_DB}}.PUBLIC;

-- =============================================================================
-- BUDGETS: centre x GL account x FY (23 x 20 x 5 = 2,300)
-- Budget = that year's approved spend x lognormal noise (slightly generous).
-- FY2027 (in progress) is budgeted off FY2026 actuals + 6%.
-- FY2026: large lines (> $300K) are capped at 8% overspend so that material
-- overruns are controlled by 05_planted_scenarios.sql.
-- =============================================================================
CREATE OR REPLACE TABLE BUDGETS (
  BUDGET_ID        VARCHAR      COMMENT 'Primary key',
  PROFIT_CENTRE_ID VARCHAR      COMMENT 'Centre the budget belongs to. Joins to PROFIT_CENTRES.PROFIT_CENTRE_ID',
  GL_ACCOUNT_ID    VARCHAR      COMMENT 'GL account budgeted. Joins to GL_HIERARCHY.GL_ACCOUNT_ID',
  GL_CATEGORY      VARCHAR      COMMENT 'GL category, denormalised from GL_HIERARCHY.GL_CATEGORY',
  FINANCIAL_YEAR   VARCHAR      COMMENT 'Financial year (July–June) the budget applies to, FY2023–FY2027',
  BUDGET_AMOUNT    NUMBER(12,2) COMMENT 'Annual budget in AUD. 0 where the line does not apply (e.g. pool operations at centres without a pool)',
  APPROVED_BY      VARCHAR      COMMENT 'CFO / COO / Regional Director / Finance Manager',
  APPROVED_DATE    DATE         COMMENT 'Approval date, typically mid-June before the financial year starts'
) COMMENT = 'Annual budget allocations by profit centre, GL account and financial year (one row per centre x GL account x FY).';

INSERT INTO BUDGETS
WITH FY AS (
  SELECT DISTINCT FINANCIAL_YEAR FROM {{BUILD_DB}}.GEN.MONTHS
), GRID AS (
  SELECT P.PROFIT_CENTRE_ID, P.CENTRE_SIZE, G.GL_ACCOUNT_ID, G.GL_CATEGORY, FY.FINANCIAL_YEAR
  FROM PROFIT_CENTRES P CROSS JOIN GL_HIERARCHY G CROSS JOIN FY
), ACT AS (
  SELECT PROFIT_CENTRE_ID, GL_ACCOUNT_ID, FINANCIAL_YEAR, SUM(AMOUNT) AS ACTUAL
  FROM PO_TRANSACTIONS WHERE STATUS = 'Approved' GROUP BY 1, 2, 3
), BASE AS (
  SELECT GR.*,
         CASE WHEN GR.FINANCIAL_YEAR = 'FY2027' THEN COALESCE(A26.ACTUAL, 0) * 1.06
              ELSE COALESCE(A.ACTUAL, 0) END AS BASE_SPEND,
         COALESCE(A.ACTUAL, 0) AS ACTUAL
  FROM GRID GR
  LEFT JOIN ACT A   ON A.PROFIT_CENTRE_ID = GR.PROFIT_CENTRE_ID AND A.GL_ACCOUNT_ID = GR.GL_ACCOUNT_ID AND A.FINANCIAL_YEAR = GR.FINANCIAL_YEAR
  LEFT JOIN ACT A26 ON A26.PROFIT_CENTRE_ID = GR.PROFIT_CENTRE_ID AND A26.GL_ACCOUNT_ID = GR.GL_ACCOUNT_ID AND A26.FINANCIAL_YEAR = 'FY2026'
), AMT AS (
  SELECT BASE.*,
         CASE WHEN BASE_SPEND = 0 THEN 0
              ELSE GREATEST(1000,
                     ROUND(
                       IFF(FINANCIAL_YEAR = 'FY2026' AND BASE_SPEND > 300000,
                           GREATEST(BASE_SPEND * EXP(0.03 + 0.07 * {{BUILD_DB}}.GEN.N(PROFIT_CENTRE_ID || GL_ACCOUNT_ID || FINANCIAL_YEAR || ':bud')),
                                    BASE_SPEND / 1.08),
                           BASE_SPEND * EXP(0.03 + 0.07 * {{BUILD_DB}}.GEN.N(PROFIT_CENTRE_ID || GL_ACCOUNT_ID || FINANCIAL_YEAR || ':bud')))
                     , -2)) END AS BUDGET_AMOUNT
  FROM BASE
)
SELECT
  'BUD' || LPAD(ROW_NUMBER() OVER (ORDER BY FINANCIAL_YEAR, PROFIT_CENTRE_ID, GL_ACCOUNT_ID), 5, '0'),
  PROFIT_CENTRE_ID, GL_ACCOUNT_ID, GL_CATEGORY, FINANCIAL_YEAR, BUDGET_AMOUNT,
  CASE WHEN BUDGET_AMOUNT >= 1000000 OR GL_CATEGORY = 'Capital' THEN 'CFO'
       WHEN GL_CATEGORY = 'Operations' AND BUDGET_AMOUNT >= 250000 THEN 'COO'
       WHEN BUDGET_AMOUNT >= 100000 THEN 'Regional Director'
       ELSE 'Finance Manager' END,
  DATEADD(DAY, 8 + FLOOR({{BUILD_DB}}.GEN.U(PROFIT_CENTRE_ID || GL_ACCOUNT_ID || FINANCIAL_YEAR || ':appr') * 14),
          DATE_FROM_PARTS(TO_NUMBER(SUBSTR(FINANCIAL_YEAR, 3)) - 1, 6, 1))
FROM AMT;

-- =============================================================================
-- Workforce role profile (GEN)
-- =============================================================================
CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.ROLE_PROFILE AS
SELECT * FROM VALUES
  -- role, code, base large/medium/small, FTE ratio, base hourly rate, seasonal
  ('Personal Trainer',         'PT', 10, 7, 4, 0.60, 38.00, TRUE),
  ('Group Fitness Instructor', 'GF',  9, 6, 3, 0.40, 42.00, TRUE),
  ('Reception Staff',          'RC',  7, 4, 2, 0.70, 28.00, TRUE),
  ('Cleaning & Maintenance',   'CM',  5, 3, 1, 0.80, 27.00, FALSE),
  ('Centre Manager',           'MG',  1, 1, 1, 1.00, 68.00, FALSE),
  ('Sales Consultant',         'SC',  4, 3, 1, 0.90, 32.00, TRUE),
  ('Pool Lifeguard',           'LG',  5, 3, 0, 0.50, 29.00, TRUE),
  ('Admin & Finance',          'AF',  3, 1, 1, 0.90, 36.00, FALSE)
  AS V(ROLE_TYPE, ROLE_CODE, BASE_LARGE, BASE_MEDIUM, BASE_SMALL, FTE_RATIO, BASE_RATE, SEASONAL);

-- Headcount per centre x role x month (no Pool Lifeguard at non-pool centres)
CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.ROSTER_BASE AS
SELECT
  P.PROFIT_CENTRE_ID, R.ROLE_TYPE, R.ROLE_CODE, R.FTE_RATIO, R.BASE_RATE, M.MONTH_START, M.MONTH_IDX,
  GREATEST(1, ROUND(
    DECODE(P.CENTRE_SIZE, 'large', R.BASE_LARGE, 'medium', R.BASE_MEDIUM, R.BASE_SMALL)
    * IFF(R.SEASONAL,
          DECODE(MONTH(M.MONTH_START), 1,1.12, 2,1.12, 3,1.05, 4,1.00, 5,0.97, 6,0.92,
                                       7,0.92, 8,0.96, 9,1.00, 10,1.02, 11,1.04, 12,1.00), 1)
    * (1 + 0.02 * M.MONTH_IDX / 12)
    * (1 + 0.05 * {{BUILD_DB}}.GEN.N(P.PROFIT_CENTRE_ID || R.ROLE_CODE || M.MONTH_IDX || ':hc'))
  )) AS HEADCOUNT
FROM PROFIT_CENTRES P
CROSS JOIN {{BUILD_DB}}.GEN.ROLE_PROFILE R
CROSS JOIN {{BUILD_DB}}.GEN.MONTHS M
WHERE R.ROLE_TYPE <> 'Pool Lifeguard' OR P.HAS_POOL;

-- =============================================================================
-- STAFF_COSTS: one row per staff member per semi-monthly pay period
-- =============================================================================
CREATE OR REPLACE TABLE STAFF_COSTS (
  COST_ID          VARCHAR      COMMENT 'Primary key',
  PROFIT_CENTRE_ID VARCHAR      COMMENT 'Centre the staff member works at. Joins to PROFIT_CENTRES.PROFIT_CENTRE_ID',
  MONTH            DATE         COMMENT 'Pay month (first day of month)',
  PAY_PERIOD       NUMBER       COMMENT 'Semi-monthly pay period: 1 = 1st–15th, 2 = 16th–end of month',
  STAFF_ID         VARCHAR      COMMENT 'Individual staff identifier (no staff dimension table)',
  ROLE_TYPE        VARCHAR      COMMENT 'Same 8 role types as STAFF_ROSTER.ROLE_TYPE',
  HOURS_WORKED     NUMBER(5,1)  COMMENT 'Hours worked in the pay period (30–88)',
  HOURLY_RATE      NUMBER(6,2)  COMMENT 'Hourly pay rate in AUD',
  TOTAL_COST       NUMBER(10,2) COMMENT 'HOURS_WORKED x HOURLY_RATE, AUD'
) COMMENT = 'Individual staff pay records, one row per staff member per semi-monthly pay period. Rows per centre/role/month equal STAFF_ROSTER.HEADCOUNT x 2.';

INSERT INTO STAFF_COSTS
WITH SLOTS AS (
  SELECT RB.*, S.N AS SLOT, PP.PAY_PERIOD,
         'S' || SUBSTR(RB.PROFIT_CENTRE_ID, 3) || RB.ROLE_CODE || LPAD(S.N + 1, 2, '0') AS STAFF_ID
  FROM {{BUILD_DB}}.GEN.ROSTER_BASE RB
  JOIN {{BUILD_DB}}.GEN.SEQ S ON S.N < RB.HEADCOUNT
  CROSS JOIN (SELECT 1 AS PAY_PERIOD UNION ALL SELECT 2) PP
), C AS (
  SELECT SLOTS.*,
         LEAST(88, GREATEST(30, ROUND(80 * FTE_RATIO * (1 + 0.15 * {{BUILD_DB}}.GEN.N(STAFF_ID || MONTH_IDX || PAY_PERIOD || ':hrs')), 1))) AS HOURS_WORKED,
         ROUND(BASE_RATE * (1 + 0.05 * {{BUILD_DB}}.GEN.N(STAFF_ID || ':rate')) * POWER(1.03, MONTH_IDX / 12), 2) AS HOURLY_RATE
  FROM SLOTS
)
SELECT
  'CST' || LPAD(ROW_NUMBER() OVER (ORDER BY MONTH_START, PAY_PERIOD, PROFIT_CENTRE_ID, STAFF_ID), 6, '0'),
  PROFIT_CENTRE_ID, MONTH_START, PAY_PERIOD, STAFF_ID, ROLE_TYPE, HOURS_WORKED, HOURLY_RATE,
  ROUND(HOURS_WORKED * HOURLY_RATE, 2)
FROM C;

-- =============================================================================
-- STAFF_ROSTER: monthly snapshot; FTE derived from hours paid that month
-- (160 hours per month = 1 FTE)
-- =============================================================================
CREATE OR REPLACE TABLE STAFF_ROSTER (
  ROSTER_ID        VARCHAR     COMMENT 'Primary key',
  PROFIT_CENTRE_ID VARCHAR     COMMENT 'Centre. Joins to PROFIT_CENTRES.PROFIT_CENTRE_ID',
  ROLE_TYPE        VARCHAR     COMMENT 'Personal Trainer, Group Fitness Instructor, Reception Staff, Cleaning & Maintenance, Centre Manager, Sales Consultant, Pool Lifeguard (pool centres only), Admin & Finance',
  MONTH            DATE        COMMENT 'Snapshot month (first day of month), Jul 2022 – Oct 2026',
  HEADCOUNT        NUMBER      COMMENT 'Staff on the roster that month. Semi-additive: do not sum across months (use the latest month or a monthly average)',
  FTE_EQUIVALENT   NUMBER(6,1) COMMENT 'Full-time equivalent (hours paid that month / 160). Semi-additive like HEADCOUNT'
) COMMENT = 'Monthly headcount snapshot by centre and role type (one row per centre x role x month).';

INSERT INTO STAFF_ROSTER
SELECT
  'RST' || LPAD(ROW_NUMBER() OVER (ORDER BY RB.MONTH_START, RB.PROFIT_CENTRE_ID, RB.ROLE_CODE), 6, '0'),
  RB.PROFIT_CENTRE_ID, RB.ROLE_TYPE, RB.MONTH_START, RB.HEADCOUNT,
  ROUND(SC.HOURS / 160, 1)
FROM {{BUILD_DB}}.GEN.ROSTER_BASE RB
JOIN (SELECT PROFIT_CENTRE_ID, ROLE_TYPE, MONTH, SUM(HOURS_WORKED) AS HOURS
      FROM STAFF_COSTS GROUP BY 1, 2, 3) SC
  ON SC.PROFIT_CENTRE_ID = RB.PROFIT_CENTRE_ID AND SC.ROLE_TYPE = RB.ROLE_TYPE AND SC.MONTH = RB.MONTH_START;

-- =============================================================================
-- BUDGET_ACTUALS_VW (validation copy in build area; demo copy at promotion)
-- =============================================================================
CREATE OR REPLACE VIEW BUDGET_ACTUALS_VW
  COMMENT = 'Budget vs actual approved PO spend by centre, GL account and FY. VARIANCE = budget - actual (negative = overspend).'
AS
SELECT
  B.BUDGET_ID, B.PROFIT_CENTRE_ID, B.GL_ACCOUNT_ID, B.GL_CATEGORY, B.FINANCIAL_YEAR, B.BUDGET_AMOUNT,
  COALESCE(A.ACTUAL_SPEND, 0)                                              AS ACTUAL_SPEND,
  B.BUDGET_AMOUNT - COALESCE(A.ACTUAL_SPEND, 0)                            AS VARIANCE,
  ROUND((B.BUDGET_AMOUNT - COALESCE(A.ACTUAL_SPEND, 0)) / NULLIF(B.BUDGET_AMOUNT, 0), 4) AS VARIANCE_PCT,
  CASE WHEN COALESCE(A.ACTUAL_SPEND, 0) > 1.10 * B.BUDGET_AMOUNT THEN 'Over Budget'
       WHEN COALESCE(A.ACTUAL_SPEND, 0) > B.BUDGET_AMOUNT        THEN 'Slightly Over'
       WHEN COALESCE(A.ACTUAL_SPEND, 0) >= 0.90 * B.BUDGET_AMOUNT THEN 'On Track'
       ELSE 'Under Budget' END                                             AS BUDGET_STATUS
FROM BUDGETS B
LEFT JOIN (
  SELECT PROFIT_CENTRE_ID, GL_ACCOUNT_ID, FINANCIAL_YEAR, SUM(AMOUNT) AS ACTUAL_SPEND
  FROM PO_TRANSACTIONS
  WHERE STATUS = 'Approved'
  GROUP BY 1, 2, 3
) A ON A.PROFIT_CENTRE_ID = B.PROFIT_CENTRE_ID
   AND A.GL_ACCOUNT_ID = B.GL_ACCOUNT_ID
   AND A.FINANCIAL_YEAR = B.FINANCIAL_YEAR;
