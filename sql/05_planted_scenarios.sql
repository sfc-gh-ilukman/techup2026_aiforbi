-- =============================================================================
-- 05_planted_scenarios.sql — deliberate business scenarios (build area)
-- Run once after 01–04. Re-running requires re-running 01–04 first.
--
-- Q2 (as at 2026-10-31): at-risk suppliers with Active, non auto-renew
-- contracts ending within 90 days (2026-10-31 .. 2027-01-29) + FY2026 spend.
--   Golden:  SUP015, SUP026, SUP040 (scores)   SUP014 (incidents)
--   Decoys:  SUP032 lexical period sort        SUP022 'Not Recommended' only
--            SUP050 auto-renew contract        SUP008 contract ends day 106
--            SUP030 contract Under Renewal     SUP037 one low period only
--            SUP034 incidents via asset warranty only
-- Also: PO splitting (4 buyers) and FY2026 material budget overruns (4 lines).
-- =============================================================================

USE ROLE {{ROLE}};
USE WAREHOUSE {{WH}};
USE SCHEMA {{BUILD_DB}}.PUBLIC;

-- =============================================================================
-- A. Supplier assessment scores
-- Shift each supplier's centre-level scores so the supplier-level average
-- (mean OVERALL_SCORE across centres) hits the target for that period.
-- =============================================================================
CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.PLANT_SCORES AS
SELECT * FROM VALUES
  ('SUP015','H1-FY2026',2.78), ('SUP015','H2-FY2026',2.64),
  ('SUP026','H1-FY2026',2.71), ('SUP026','H2-FY2026',2.85),
  ('SUP040','H1-FY2026',2.88), ('SUP040','H2-FY2026',2.59),
  ('SUP032','H2-FY2025',2.74), ('SUP032','H2-FY2026',2.81),
  ('SUP050','H1-FY2026',2.66), ('SUP050','H2-FY2026',2.72),
  ('SUP008','H1-FY2026',2.81), ('SUP008','H2-FY2026',2.69),
  ('SUP030','H1-FY2026',2.75), ('SUP030','H2-FY2026',2.62),
  ('SUP037','H1-FY2026',3.24), ('SUP037','H2-FY2026',2.68),
  ('SUP022','H1-FY2026',3.21), ('SUP022','H2-FY2026',3.12)
  AS V(SUPPLIER_ID, ASSESSMENT_PERIOD, TARGET);

UPDATE SUPPLIER_ASSESSMENTS SA
SET QUALITY_SCORE         = LEAST(5, GREATEST(1, ROUND(SA.QUALITY_SCORE + D.DELTA, 2))),
    TIMELINESS_SCORE      = LEAST(5, GREATEST(1, ROUND(SA.TIMELINESS_SCORE + D.DELTA, 2))),
    COMMUNICATION_SCORE   = LEAST(5, GREATEST(1, ROUND(SA.COMMUNICATION_SCORE + D.DELTA, 2))),
    VALUE_FOR_MONEY_SCORE = LEAST(5, GREATEST(1, ROUND(SA.VALUE_FOR_MONEY_SCORE + D.DELTA, 2)))
FROM (
  SELECT A.SUPPLIER_ID, A.ASSESSMENT_PERIOD, MAX(PS.TARGET) - AVG(A.OVERALL_SCORE) AS DELTA
  FROM SUPPLIER_ASSESSMENTS A
  JOIN {{BUILD_DB}}.GEN.PLANT_SCORES PS
    ON PS.SUPPLIER_ID = A.SUPPLIER_ID AND PS.ASSESSMENT_PERIOD = A.ASSESSMENT_PERIOD
  GROUP BY 1, 2
) D
WHERE SA.SUPPLIER_ID = D.SUPPLIER_ID AND SA.ASSESSMENT_PERIOD = D.ASSESSMENT_PERIOD;

-- Recompute overall, recommendation and comments for the shifted rows
UPDATE SUPPLIER_ASSESSMENTS SA
SET OVERALL_SCORE = ROUND((SA.QUALITY_SCORE + SA.TIMELINESS_SCORE + SA.COMMUNICATION_SCORE + SA.VALUE_FOR_MONEY_SCORE) / 4, 2)
FROM {{BUILD_DB}}.GEN.PLANT_SCORES PS
WHERE PS.SUPPLIER_ID = SA.SUPPLIER_ID AND PS.ASSESSMENT_PERIOD = SA.ASSESSMENT_PERIOD;

UPDATE SUPPLIER_ASSESSMENTS SA
SET RECOMMENDATION = CASE
      WHEN SA.OVERALL_SCORE + 0.12 * {{BUILD_DB}}.GEN.N(SA.ASSESSMENT_ID || ':rec2') >= 4.20 THEN 'Preferred'
      WHEN SA.OVERALL_SCORE + 0.12 * {{BUILD_DB}}.GEN.N(SA.ASSESSMENT_ID || ':rec2') >= 3.40 THEN 'Approved'
      WHEN SA.OVERALL_SCORE + 0.12 * {{BUILD_DB}}.GEN.N(SA.ASSESSMENT_ID || ':rec2') >= 2.60 THEN 'Conditional'
      ELSE 'Not Recommended' END,
    ASSESSOR_COMMENTS = CASE
      WHEN SA.OVERALL_SCORE >= 3.5 THEN 'Solid performance overall with minor delays.'
      WHEN SA.OVERALL_SCORE >= 3.0 THEN DECODE(FLOOR({{BUILD_DB}}.GEN.U(SA.ASSESSMENT_ID || ':c2') * 3),
                                         0, 'Quality inconsistent across visits. Raised with account manager.',
                                         1, 'Slow to respond to callouts. Improvement plan discussed.',
                                            'Several missed service windows this period. Monitoring closely.')
      ELSE DECODE(FLOOR({{BUILD_DB}}.GEN.U(SA.ASSESSMENT_ID || ':c2') * 4),
                  0, 'Repeated quality failures. Escalated to procurement.',
                  1, 'Service levels well below contract. Considering alternatives.',
                  2, 'Poor communication and frequent no-shows.',
                     'Significant rework required. Not meeting agreed standards.') END
FROM {{BUILD_DB}}.GEN.PLANT_SCORES PS
WHERE PS.SUPPLIER_ID = SA.SUPPLIER_ID AND PS.ASSESSMENT_PERIOD = SA.ASSESSMENT_PERIOD;

-- Decoy SUP022: assessors recommend against on commercial grounds, scores stay >= 3.00
UPDATE SUPPLIER_ASSESSMENTS
SET RECOMMENDATION = 'Not Recommended',
    ASSESSOR_COMMENTS = DECODE(FLOOR({{BUILD_DB}}.GEN.U(ASSESSMENT_ID || ':c3') * 3),
                          0, 'Pricing well above market at renewal. Recommend going to market before re-engaging.',
                          1, 'Commercial terms not competitive. Recommend an alternative booking platform.',
                             'Service adequate but licence costs rising sharply. Not recommended for renewal on current terms.')
WHERE SUPPLIER_ID = 'SUP022'
  AND ((ASSESSMENT_PERIOD = 'H2-FY2026' AND {{BUILD_DB}}.GEN.U(ASSESSMENT_ID || ':nr') < 0.85)
    OR (ASSESSMENT_PERIOD = 'H1-FY2026' AND {{BUILD_DB}}.GEN.U(ASSESSMENT_ID || ':nr') < 0.45));

-- =============================================================================
-- B. Contracts (window = END_DATE 2026-10-31 .. 2027-01-29)
-- =============================================================================
CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.PLANT_CONTRACTS AS
SELECT V.SUPPLIER_ID, V.END_DATE::DATE AS END_DATE, V.RENEWAL_TYPE, V.CONTRACT_STATUS, V.CLEAR_WINDOW
FROM VALUES
  ('SUP015','2026-12-14','KEEP','Active',FALSE),
  ('SUP026','2027-01-12','KEEP','Active',FALSE),
  ('SUP032','2026-11-27','KEEP','Active',FALSE),
  ('SUP037','2027-01-05','KEEP','Active',FALSE),
  ('SUP050','2026-12-20','Auto-renew','Active',TRUE),
  ('SUP008','2027-02-14','KEEP','Active',TRUE),
  ('SUP030','2026-12-05','KEEP','Under Renewal',TRUE)
  AS V(SUPPLIER_ID, END_DATE, RENEWAL_TYPE, CONTRACT_STATUS, CLEAR_WINDOW);

-- Decoys whose only reason to be excluded is the planted contract: push any
-- other Active / Under Renewal non auto-renew contract out of the window
UPDATE CONTRACTS C
SET END_DATE = '2027-05-31'::DATE, CONTRACT_STATUS = 'Active'
FROM {{BUILD_DB}}.GEN.PLANT_CONTRACTS PC
WHERE PC.SUPPLIER_ID = C.SUPPLIER_ID AND PC.CLEAR_WINDOW
  AND C.CONTRACT_STATUS IN ('Active', 'Under Renewal')
  AND C.END_DATE BETWEEN '2026-10-31'::DATE AND '2027-02-28'::DATE;

-- Re-point each supplier's most recent contract to the planted end date
UPDATE CONTRACTS C
SET END_DATE        = PC.END_DATE,
    START_DATE      = IFF(PC.RENEWAL_TYPE = 'Auto-renew', DATEADD(DAY, 1, DATEADD(YEAR, -1, PC.END_DATE)),
                          LEAST(C.START_DATE, DATEADD(DAY, 1, DATEADD(YEAR, -1, PC.END_DATE)))),
    RENEWAL_TYPE    = IFF(PC.RENEWAL_TYPE = 'KEEP', IFF(C.RENEWAL_TYPE = 'Auto-renew', 'Annual', C.RENEWAL_TYPE), PC.RENEWAL_TYPE),
    CONTRACT_STATUS = PC.CONTRACT_STATUS
FROM {{BUILD_DB}}.GEN.PLANT_CONTRACTS PC,
     (SELECT SUPPLIER_ID, CONTRACT_ID FROM CONTRACTS
      QUALIFY ROW_NUMBER() OVER (PARTITION BY SUPPLIER_ID ORDER BY END_DATE DESC, CONTRACT_ID DESC) = 1) L
WHERE PC.SUPPLIER_ID = C.SUPPLIER_ID AND L.CONTRACT_ID = C.CONTRACT_ID;

-- =============================================================================
-- C. Incidents (rule window: INCIDENT_DATE 2026-05-01 .. 2026-10-31)
-- =============================================================================
-- C1. Cap every supplier except SUP014 at 2 PO-linked High/Critical incidents
-- (from 2026-04-01 so any reading of "last 6 months" gives the same answer)
UPDATE INCIDENT_LOG I
SET SEVERITY = 'Medium'
FROM (
  SELECT I2.INCIDENT_ID
  FROM INCIDENT_LOG I2 JOIN PO_TRANSACTIONS P ON P.PO_ID = I2.RELATED_PO_ID
  WHERE I2.INCIDENT_DATE BETWEEN '2026-04-01'::DATE AND '2026-10-31'::DATE
    AND I2.SEVERITY IN ('High', 'Critical') AND P.SUPPLIER_ID <> 'SUP014'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY P.SUPPLIER_ID ORDER BY I2.INCIDENT_ID) > 2
) X
WHERE X.INCIDENT_ID = I.INCIDENT_ID;

-- C2. Golden SUP014: exactly 4 PO-linked High/Critical incidents, all dated
-- 2026-05-15 or later
UPDATE INCIDENT_LOG I
SET SEVERITY = 'Medium'
FROM PO_TRANSACTIONS P
WHERE P.PO_ID = I.RELATED_PO_ID AND P.SUPPLIER_ID = 'SUP014'
  AND I.INCIDENT_DATE BETWEEN '2026-04-01'::DATE AND '2026-10-31'::DATE
  AND I.SEVERITY IN ('High', 'Critical');

UPDATE INCIDENT_LOG I
SET SEVERITY = IFF(X.RN = 3, 'Critical', 'High')
FROM (
  SELECT I2.INCIDENT_ID, ROW_NUMBER() OVER (ORDER BY HASH(I2.INCIDENT_ID, 'sup014')) AS RN
  FROM INCIDENT_LOG I2 JOIN PO_TRANSACTIONS P ON P.PO_ID = I2.RELATED_PO_ID
  WHERE I2.INCIDENT_DATE BETWEEN '2026-05-15'::DATE AND '2026-10-31'::DATE AND P.SUPPLIER_ID = 'SUP014'
) X
WHERE X.INCIDENT_ID = I.INCIDENT_ID AND X.RN <= 4;

-- C3. Decoy SUP034: 3 High/Critical pool incidents linked only via assets under
-- SUP034 warranty (no PO link) — warranty-linked incidents do not count
UPDATE INCIDENT_LOG I
SET SEVERITY = IFF(X.RN = 2, 'Critical', 'High'),
    RELATED_PO_ID = NULL,
    RELATED_ASSET_ID = X.ASSET_ID
FROM (
  SELECT I2.INCIDENT_ID, A.ASSET_ID,
         ROW_NUMBER() OVER (ORDER BY HASH(I2.INCIDENT_ID, 'sup034')) AS RN
  FROM INCIDENT_LOG I2
  JOIN (SELECT PROFIT_CENTRE_ID, ASSET_ID FROM ASSET_REGISTER
        WHERE WARRANTY_SUPPLIER_ID = 'SUP034' AND ASSET_CATEGORY = 'Pool' AND PURCHASE_DATE < '2026-05-01'::DATE
        QUALIFY ROW_NUMBER() OVER (PARTITION BY PROFIT_CENTRE_ID ORDER BY ASSET_ID) = 1) A
    ON A.PROFIT_CENTRE_ID = I2.PROFIT_CENTRE_ID
  WHERE I2.INCIDENT_DATE BETWEEN '2026-05-15'::DATE AND '2026-10-31'::DATE
    AND I2.INCIDENT_TYPE = 'Pool Plant Failure'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY I2.PROFIT_CENTRE_ID ORDER BY HASH(I2.INCIDENT_ID, 'sup034')) = 1
) X
WHERE X.INCIDENT_ID = I.INCIDENT_ID AND X.RN <= 3;

-- =============================================================================
-- D. PO splitting: 4 buyers raise clusters of 2–3 POs to the same supplier on
-- the same spend code within 3 days, each between $4,000 and $5,000 (just under
-- the $5,000 Self approval limit) and combined above it.
-- =============================================================================
CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.SPLIT_PLAN AS
WITH P AS (
  SELECT PO_ID, BUYER_ID, SUPPLIER_ID, PO_DATE, SPEND_CODE_ID, GL_ACCOUNT_ID, DESCRIPTION, AMOUNT,
         DATE_TRUNC(MONTH, PO_DATE) AS M
  FROM PO_TRANSACTIONS
  WHERE STATUS = 'Approved' AND BUYER_ID IN ('BUY008', 'BUY012', 'BUY020', 'BUY026')
    AND PO_DATE BETWEEN '2024-07-01'::DATE AND '2026-10-24'::DATE
), MONTHS_PICKED AS (
  -- FY2026: 7 months per buyer; FY2025: 3; FY2027: 2
  SELECT DISTINCT BUYER_ID, M FROM P
  WHERE {{BUILD_DB}}.GEN.U(BUYER_ID || ':' || M || ':split') <
        CASE WHEN M BETWEEN '2025-07-01' AND '2026-06-01' THEN 0.58
             WHEN M < '2025-07-01' THEN 0.25 ELSE 0.5 END
), ANCHOR AS (
  SELECT A.PO_ID AS ANCHOR_PO, A.BUYER_ID, A.SUPPLIER_ID, A.PO_DATE AS ANCHOR_DATE,
         A.SPEND_CODE_ID, A.GL_ACCOUNT_ID, A.DESCRIPTION
  FROM P A
  JOIN MONTHS_PICKED MP ON MP.BUYER_ID = A.BUYER_ID AND MP.M = A.M
  WHERE EXISTS (SELECT 1 FROM P B WHERE B.BUYER_ID = A.BUYER_ID AND B.SUPPLIER_ID = A.SUPPLIER_ID
                AND B.PO_ID <> A.PO_ID AND B.PO_DATE BETWEEN A.PO_DATE AND DATEADD(DAY, 3, A.PO_DATE))
  QUALIFY ROW_NUMBER() OVER (PARTITION BY A.BUYER_ID, A.M ORDER BY HASH(A.PO_ID, 'anchor')) = 1
), MEMBERS AS (
  SELECT AN.*, B.PO_ID,
         ROW_NUMBER() OVER (PARTITION BY AN.ANCHOR_PO ORDER BY IFF(B.PO_ID = AN.ANCHOR_PO, 0, 1), B.PO_DATE, B.PO_ID) AS K
  FROM ANCHOR AN
  JOIN P B ON B.BUYER_ID = AN.BUYER_ID AND B.SUPPLIER_ID = AN.SUPPLIER_ID
          AND B.PO_DATE BETWEEN AN.ANCHOR_DATE AND DATEADD(DAY, 3, AN.ANCHOR_DATE)
)
SELECT M.ANCHOR_PO, M.PO_ID, M.K, M.BUYER_ID, M.SUPPLIER_ID, M.SPEND_CODE_ID, M.GL_ACCOUNT_ID, M.DESCRIPTION,
       P.AMOUNT AS OLD_AMOUNT,
       ROUND(4150 + 800 * {{BUILD_DB}}.GEN.U(M.PO_ID || ':splitamt'), 2) AS NEW_AMOUNT
FROM MEMBERS M JOIN PO_TRANSACTIONS P ON P.PO_ID = M.PO_ID
WHERE M.K <= 3
QUALIFY ROW_NUMBER() OVER (PARTITION BY M.PO_ID ORDER BY M.ANCHOR_PO) = 1;

UPDATE PO_TRANSACTIONS P
SET AMOUNT = S.NEW_AMOUNT, SPEND_CODE_ID = S.SPEND_CODE_ID, GL_ACCOUNT_ID = S.GL_ACCOUNT_ID,
    DESCRIPTION = S.DESCRIPTION, APPROVAL_LEVEL = 'Self'
FROM {{BUILD_DB}}.GEN.SPLIT_PLAN S
WHERE S.PO_ID = P.PO_ID;

-- Rescale the split POs' invoices so they still sum to the PO amount
UPDATE PO_INVOICES I
SET INVOICE_AMOUNT = X.NEW_INV
FROM (
  SELECT I2.INVOICE_ID,
         IFF(ROW_NUMBER() OVER (PARTITION BY I2.PO_ID ORDER BY I2.INVOICE_DATE DESC, I2.INVOICE_ID DESC) = 1,
             S.NEW_AMOUNT * (SUM(I2.INVOICE_AMOUNT) OVER (PARTITION BY I2.PO_ID) / S.OLD_AMOUNT)
               - COALESCE(SUM(ROUND(I2.INVOICE_AMOUNT * S.NEW_AMOUNT / S.OLD_AMOUNT, 2)) OVER (PARTITION BY I2.PO_ID ORDER BY I2.INVOICE_DATE, I2.INVOICE_ID
                                                                                     ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0),
             ROUND(I2.INVOICE_AMOUNT * S.NEW_AMOUNT / S.OLD_AMOUNT, 2)) AS NEW_INV
  FROM PO_INVOICES I2 JOIN {{BUILD_DB}}.GEN.SPLIT_PLAN S ON S.PO_ID = I2.PO_ID
) X
WHERE X.INVOICE_ID = I.INVOICE_ID;

-- =============================================================================
-- E. Material budget overruns (FY2026): 4 large operating lines over budget by
-- > 10% and > $50K. (Natural data has lines over by > 10% but < $50K, and lines
-- over by > $50K but < 10% — these are the decoys.)
-- =============================================================================
CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.PLANT_OVERRUNS AS
WITH ACT AS (
  SELECT P.PROFIT_CENTRE_ID, P.GL_ACCOUNT_ID, SUM(P.AMOUNT) AS ACTUAL
  FROM PO_TRANSACTIONS P
  WHERE P.STATUS = 'Approved' AND P.FINANCIAL_YEAR = 'FY2026'
  GROUP BY 1, 2
), C AS (
  SELECT A.*, PC.STATE, G.GL_CATEGORY,
         ROW_NUMBER() OVER (PARTITION BY PC.STATE ORDER BY HASH(A.PROFIT_CENTRE_ID, A.GL_ACCOUNT_ID, 'overrun')) AS RN_STATE
  FROM ACT A
  JOIN PROFIT_CENTRES PC ON PC.PROFIT_CENTRE_ID = A.PROFIT_CENTRE_ID
  JOIN GL_HIERARCHY G ON G.GL_ACCOUNT_ID = A.GL_ACCOUNT_ID
  WHERE A.ACTUAL BETWEEN 600000 AND 2500000 AND G.GL_CATEGORY IN ('Operations', 'Technology', 'Marketing')
    AND PC.STATE IN ('NSW', 'VIC', 'QLD', 'WA')
)
SELECT PROFIT_CENTRE_ID, GL_ACCOUNT_ID, ACTUAL,
       DECODE(STATE, 'NSW', 1.13, 'VIC', 1.17, 'QLD', 1.21, 1.26) AS RATIO
FROM C WHERE RN_STATE = 1;

UPDATE BUDGETS B
SET BUDGET_AMOUNT = ROUND(O.ACTUAL / O.RATIO, -2)
FROM {{BUILD_DB}}.GEN.PLANT_OVERRUNS O
WHERE B.PROFIT_CENTRE_ID = O.PROFIT_CENTRE_ID AND B.GL_ACCOUNT_ID = O.GL_ACCOUNT_ID AND B.FINANCIAL_YEAR = 'FY2026';

-- FY2027 (in progress) lines with no FY2026 base: give them a working budget
UPDATE BUDGETS B
SET BUDGET_AMOUNT = GREATEST(5000, ROUND(A.ACTUAL * 3, -2))
FROM (SELECT PROFIT_CENTRE_ID, GL_ACCOUNT_ID, SUM(AMOUNT) AS ACTUAL
      FROM PO_TRANSACTIONS WHERE STATUS = 'Approved' AND FINANCIAL_YEAR = 'FY2027' GROUP BY 1, 2) A
WHERE B.PROFIT_CENTRE_ID = A.PROFIT_CENTRE_ID AND B.GL_ACCOUNT_ID = A.GL_ACCOUNT_ID
  AND B.FINANCIAL_YEAR = 'FY2027' AND B.BUDGET_AMOUNT < A.ACTUAL;
