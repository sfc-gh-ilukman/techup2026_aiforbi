-- =============================================================================
-- 02_procurement_facts.sql — PO_TRANSACTIONS + PO_INVOICES (build area)
-- Depends on 01_dimensions.sql. As-at date 2026-10-31.
-- =============================================================================

USE ROLE {{ROLE}};
USE WAREHOUSE {{WH}};
USE SCHEMA {{BUILD_DB}}.PUBLIC;

-- -----------------------------------------------------------------------------
-- PO description templates ({c} = centre short name)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.DESC_TEMPLATES AS
SELECT SPEND_CODE_NAME, ROW_NUMBER() OVER (PARTITION BY SPEND_CODE_NAME ORDER BY TEMPLATE) - 1 AS IDX,
       COUNT(*) OVER (PARTITION BY SPEND_CODE_NAME) AS N_TEMPLATES, TEMPLATE
FROM VALUES
  ('Cleaning Services','Monthly contract cleaning – {c}'),
  ('Cleaning Services','Deep clean of change rooms – {c}'),
  ('Cleaning Services','After-hours sanitisation service – {c}'),
  ('Waste Management','General waste and recycling collection – {c}'),
  ('Waste Management','Bin hire and waste removal – {c}'),
  ('Building Maintenance','Reactive building repairs – {c}'),
  ('Building Maintenance','Painting and minor works – {c}'),
  ('Building Maintenance','Door and locker repairs – {c}'),
  ('Plumbing & Electrical','Plumbing repairs to showers – {c}'),
  ('Plumbing & Electrical','Electrical fault rectification – {c}'),
  ('Plumbing & Electrical','Lighting upgrade works – {c}'),
  ('Utilities','Electricity supply – {c}'),
  ('Utilities','Water and sewerage charges – {c}'),
  ('Utilities','Gas supply – {c}'),
  ('Pool Chemicals','Pool chlorine and pH chemicals – {c}'),
  ('Pool Chemicals','Water treatment chemicals – {c}'),
  ('Pool Maintenance','Pool plant servicing – {c}'),
  ('Pool Maintenance','Pool filter maintenance – {c}'),
  ('Pool Maintenance','Lane rope and pool equipment repairs – {c}'),
  ('Security Services','Security patrols and monitoring – {c}'),
  ('Security Services','CCTV maintenance – {c}'),
  ('Security Services','Access control servicing – {c}'),
  ('Fitness Equipment Purchase','Treadmill purchase – {c}'),
  ('Fitness Equipment Purchase','Strength equipment purchase – {c}'),
  ('Fitness Equipment Purchase','Free weights and racks – {c}'),
  ('Fitness Equipment Purchase','Spin bikes for studio – {c}'),
  ('Equipment Repairs','Cardio equipment servicing – {c}'),
  ('Equipment Repairs','Strength machine repairs – {c}'),
  ('Equipment Repairs','Preventive maintenance visit – {c}'),
  ('IT Services','IT support and helpdesk – {c}'),
  ('IT Services','Network maintenance – {c}'),
  ('IT Services','Hardware installation – {c}'),
  ('Software Licences','Member management software subscription – {c}'),
  ('Software Licences','Rostering software licences – {c}'),
  ('Software Licences','Booking platform subscription – {c}'),
  ('Digital Marketing','Social media campaign – {c}'),
  ('Digital Marketing','Paid search advertising – {c}'),
  ('Digital Marketing','Membership drive campaign – {c}'),
  ('Print & Signage','Printed promotional flyers – {c}'),
  ('Print & Signage','Signage and banners – {c}'),
  ('Legal Services','Legal advice – lease review'),
  ('Legal Services','Legal advice – employment matter'),
  ('Legal Services','Contract drafting services'),
  ('Consulting','Operational review consulting'),
  ('Consulting','Compliance audit support'),
  ('Consulting','Business improvement advisory'),
  ('Recruitment','Recruitment of personal trainers – {c}'),
  ('Recruitment','Recruitment fees – centre staff – {c}'),
  ('Office Supplies','Stationery and printer supplies – {c}'),
  ('Office Supplies','Reception consumables – {c}'),
  ('Catering Supplies','Cafe and nutrition stock – {c}'),
  ('Catering Supplies','Protein and supplement stock – {c}'),
  ('HVAC Services','HVAC preventive maintenance – {c}'),
  ('HVAC Services','Air conditioning repairs – {c}'),
  ('HVAC Services','Ventilation system servicing – {c}')
  AS V(SPEND_CODE_NAME, TEMPLATE);

-- -----------------------------------------------------------------------------
-- PO generation: centre x month volume -> one row per PO
-- Volume: size weight x seasonality x ~4%/yr growth x noise (~191K POs)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.PO_GEN AS
WITH CM AS (
  SELECT P.PROFIT_CENTRE_ID, REPLACE(P.CENTRE_NAME, 'PeakFit ', '') AS CENTRE_SHORT, P.CENTRE_SIZE,
         M.MONTH_START, M.DAYS_IN_MONTH, M.MONTH_IDX,
         ROUND(138 * DECODE(P.CENTRE_SIZE, 'large', 1.6, 'medium', 1.0, 0.6)
               * DECODE(MONTH(M.MONTH_START), 1,1.15, 2,1.12, 3,1.05, 4,1.00, 5,0.97, 6,0.92,
                                              7,0.90, 8,0.95, 9,1.00, 10,1.02, 11,1.03, 12,0.95)
               * (1 + 0.04 * M.MONTH_IDX / 12)
               * (1 + 0.08 * {{BUILD_DB}}.GEN.N(P.PROFIT_CENTRE_ID || ':' || M.MONTH_IDX || ':vol'))) AS N_PO
  FROM PROFIT_CENTRES P CROSS JOIN {{BUILD_DB}}.GEN.MONTHS M
), B AS (
  SELECT CM.*, CM.PROFIT_CENTRE_ID || ':' || CM.MONTH_IDX || ':' || S.N AS PK
  FROM CM JOIN {{BUILD_DB}}.GEN.SEQ S ON S.N < CM.N_PO
), R AS (
  SELECT B.*,
         DATEADD(DAY, FLOOR({{BUILD_DB}}.GEN.U(PK || ':day') * DAYS_IN_MONTH), MONTH_START) AS PO_DATE,
         {{BUILD_DB}}.GEN.U(PK || ':sup')    AS U_SUP,
         {{BUILD_DB}}.GEN.U(PK || ':buy')    AS U_BUY,
         {{BUILD_DB}}.GEN.U(PK || ':capex')  AS U_CAPEX,
         {{BUILD_DB}}.GEN.N(PK || ':amt')    AS Z_AMT,
         {{BUILD_DB}}.GEN.U(PK || ':sec')    AS U_SEC,
         {{BUILD_DB}}.GEN.U(PK || ':code')   AS U_CODE,
         {{BUILD_DB}}.GEN.U(PK || ':parent') AS U_PARENT,
         {{BUILD_DB}}.GEN.U(PK || ':status') AS U_STATUS,
         {{BUILD_DB}}.GEN.U(PK || ':desc')   AS U_DESC
  FROM B
), S1 AS (
  SELECT R.*, CS.SUPPLIER_ID, CS.CATEGORY, CB.BUYER_ID
  FROM R
  JOIN {{BUILD_DB}}.GEN.CENTRE_SUPPLIER CS
    ON CS.PROFIT_CENTRE_ID = R.PROFIT_CENTRE_ID
   AND R.U_SUP >= CS.CUM_LO AND R.U_SUP < IFF(CS.CUM_HI > 0.9999999, 2, CS.CUM_HI)
  JOIN {{BUILD_DB}}.GEN.CENTRE_BUYER CB
    ON CB.PROFIT_CENTRE_ID = R.PROFIT_CENTRE_ID
   AND R.U_BUY >= CB.CUM_LO AND R.U_BUY < IFF(CB.CUM_HI > 0.9999999, 2, CB.CUM_HI)
), S2 AS (
  SELECT S1.*, C.IS_GOODS, C.GL_OPEX, C.GL_CAPEX, C.CAPEX_THRESHOLD,
         (C.GL_CAPEX IS NOT NULL AND S1.U_CAPEX < C.CAPITAL_RATE) AS IS_CAPEX_PROJECT,
         IFF(SP.SPEND_SECONDARY IS NOT NULL AND S1.U_SEC < SP.SECONDARY_SHARE, SP.SPEND_SECONDARY, SP.SPEND_PRIMARY) AS SPEND_NAME,
         ROUND(
           IFF(C.GL_CAPEX IS NOT NULL AND S1.U_CAPEX < C.CAPITAL_RATE,
               DECODE(S1.CATEGORY, 'Fitness Equipment', 35000, 'HVAC Services', 60000, 90000) * EXP(0.75 * S1.Z_AMT),
               C.AMT_MEDIAN * EXP(C.AMT_SIGMA * S1.Z_AMT))
           * DECODE(S1.CENTRE_SIZE, 'large', 1.20, 'medium', 1.00, 0.80)
           * POWER(1.03, S1.MONTH_IDX / 12)
         , 2) AS AMOUNT
  FROM S1
  JOIN {{BUILD_DB}}.GEN.CATEGORY_PROFILE C ON C.CATEGORY = S1.CATEGORY
  JOIN {{BUILD_DB}}.GEN.SUPPLIER_PROFILE SP ON SP.SUPPLIER_ID = S1.SUPPLIER_ID
), S3 AS (
  SELECT S2.*,
         CASE WHEN S2.IS_CAPEX_PROJECT THEN S2.GL_CAPEX
              WHEN S2.GL_CAPEX IS NOT NULL AND S2.AMOUNT >= S2.CAPEX_THRESHOLD THEN S2.GL_CAPEX
              WHEN S2.SPEND_NAME = 'Print & Signage' THEN 'GL7520'
              ELSE S2.GL_OPEX END AS GL_CHILD,
         CASE WHEN S2.AMOUNT <= 5000 THEN 'Self'
              WHEN S2.AMOUNT <= 50000 THEN 'Manager'
              WHEN S2.AMOUNT <= 250000 THEN 'Executive'
              ELSE 'LT Panel' END AS APPROVAL_LEVEL,
         DATEDIFF(DAY, S2.PO_DATE, '2026-10-31'::DATE) AS AGE_DAYS
  FROM S2
)
SELECT
  S3.PK, S3.PROFIT_CENTRE_ID, S3.CENTRE_SHORT, S3.CENTRE_SIZE, S3.MONTH_IDX, S3.PO_DATE,
  S3.SUPPLIER_ID, S3.CATEGORY, S3.BUYER_ID, S3.IS_GOODS, S3.IS_CAPEX_PROJECT, S3.SPEND_NAME,
  SNC.SPEND_CODE_ID,
  -- ~4% of POs post to the parent (general) account of their GL
  IFF(S3.U_PARENT < 0.04 AND G.PARENT_GL_ID IS NOT NULL, G.PARENT_GL_ID, S3.GL_CHILD) AS GL_ACCOUNT_ID,
  S3.AMOUNT, S3.APPROVAL_LEVEL,
  CASE
    WHEN S3.AGE_DAYS <= 45
         AND S3.U_STATUS < 0.05 + 0.30 * (1 - S3.AGE_DAYS / 45) THEN 'Pending'
    WHEN S3.U_STATUS >= 1 - DECODE(S3.APPROVAL_LEVEL, 'Self', 0.02, 'Manager', 0.04, 'Executive', 0.08, 0.12) THEN 'Rejected'
    ELSE 'Approved' END AS STATUS,
  REPLACE(
    IFF(S3.IS_CAPEX_PROJECT,
        DECODE(S3.CATEGORY, 'Fitness Equipment', 'Gym floor equipment refresh – {c}',
                            'HVAC Services', 'HVAC system replacement – {c}',
                            'Change room and facility refurbishment – {c}'),
        DT.TEMPLATE),
    '{c}', S3.CENTRE_SHORT) AS DESCRIPTION,
  'PO' || LPAD(ROW_NUMBER() OVER (ORDER BY S3.PO_DATE, HASH(S3.PK)), 7, '0') AS PO_ID,
  'PF-' || TO_CHAR(S3.PO_DATE, 'YYMM') || '-' ||
    LPAD(ROW_NUMBER() OVER (PARTITION BY DATE_TRUNC(MONTH, S3.PO_DATE) ORDER BY S3.PO_DATE, HASH(S3.PK)), 5, '0') AS PO_NUMBER
FROM S3
JOIN GL_HIERARCHY G ON G.GL_ACCOUNT_ID = S3.GL_CHILD
JOIN {{BUILD_DB}}.GEN.SPEND_NAME_CODES SNC
  ON SNC.SPEND_CODE_NAME = S3.SPEND_NAME AND SNC.IDX = FLOOR(S3.U_CODE * SNC.N_CODES)
JOIN {{BUILD_DB}}.GEN.DESC_TEMPLATES DT
  ON DT.SPEND_CODE_NAME = S3.SPEND_NAME AND DT.IDX = FLOOR(S3.U_DESC * DT.N_TEMPLATES);

-- -----------------------------------------------------------------------------
-- PO_TRANSACTIONS
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE PO_TRANSACTIONS (
  PO_ID            VARCHAR       COMMENT 'Primary key. Referenced by PO_INVOICES.PO_ID, INCIDENT_LOG.RELATED_PO_ID and PROCUREMENT_EMAILS.RELATED_PO_ID',
  PO_NUMBER        VARCHAR       COMMENT 'Human-readable PO reference, PF-YYMM-nnnnn',
  PO_DATE          DATE          COMMENT 'Date the PO was raised (Jul 2022 – Oct 2026)',
  FINANCIAL_YEAR   VARCHAR       COMMENT 'PeakFit financial year (July–June), e.g. FY2026 = Jul 2025 – Jun 2026',
  BUYER_ID         VARCHAR       COMMENT 'Buyer who raised the PO. Joins to BUYERS.BUYER_ID',
  SUPPLIER_ID      VARCHAR       COMMENT 'Supplier. Joins to SUPPLIERS.SUPPLIER_ID',
  PROFIT_CENTRE_ID VARCHAR       COMMENT 'Centre the PO is charged to. Joins to PROFIT_CENTRES.PROFIT_CENTRE_ID',
  SPEND_CODE_ID    VARCHAR       COMMENT 'Spend code. Joins to SPEND_CODES.SPEND_CODE_ID',
  GL_ACCOUNT_ID    VARCHAR       COMMENT 'General ledger account. Joins to GL_HIERARCHY.GL_ACCOUNT_ID',
  DESCRIPTION      VARCHAR       COMMENT 'Free-text description of the goods or services ordered',
  AMOUNT           NUMBER(12,2)  COMMENT 'PO value in AUD (ex GST)',
  STATUS           VARCHAR       COMMENT 'Approved / Pending / Rejected',
  APPROVAL_LEVEL   VARCHAR       COMMENT 'Approval tier required by the PO amount: Self / Manager / Executive / LT Panel'
) COMMENT = 'Purchase orders raised by PeakFit buyers across all 23 centres (header level, one row per PO).';

INSERT INTO PO_TRANSACTIONS
SELECT
  PO_ID, PO_NUMBER, PO_DATE,
  'FY' || (YEAR(PO_DATE) + IFF(MONTH(PO_DATE) >= 7, 1, 0)),
  BUYER_ID, SUPPLIER_ID, PROFIT_CENTRE_ID, SPEND_CODE_ID, GL_ACCOUNT_ID, DESCRIPTION,
  AMOUNT, STATUS, APPROVAL_LEVEL
FROM {{BUILD_DB}}.GEN.PO_GEN;

-- Generation attributes per PO for downstream tables
CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.PO_KEYS AS
SELECT PK, PO_ID, CATEGORY, IS_GOODS, IS_CAPEX_PROJECT
FROM {{BUILD_DB}}.GEN.PO_GEN;

-- -----------------------------------------------------------------------------
-- PO_INVOICES: Approved POs only; goods 1-2 invoices, services 2-4 monthly,
-- utilities 3-4; amounts sum exactly to the PO; no invoice after 2026-10-31
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE PO_INVOICES (
  INVOICE_ID     VARCHAR      COMMENT 'Primary key. Referenced by PROCUREMENT_EMAILS.RELATED_INVOICE_ID',
  PO_ID          VARCHAR      COMMENT 'Purchase order being invoiced (Approved POs only). Joins to PO_TRANSACTIONS.PO_ID',
  SUPPLIER_ID    VARCHAR      COMMENT 'Invoicing supplier, always the PO''s supplier. Joins to SUPPLIERS.SUPPLIER_ID',
  INVOICE_DATE   DATE         COMMENT 'Invoice date (on or after the PO date)',
  DUE_DATE       DATE         COMMENT 'Payment due date (invoice date + supplier payment terms)',
  INVOICE_AMOUNT NUMBER(12,2) COMMENT 'Invoice value in AUD (ex GST)',
  PAYMENT_STATUS VARCHAR      COMMENT 'Paid / Pending / Overdue / On Hold as at 2026-10-31. Overdue = unpaid and past due date; Pending = not yet due',
  DESCRIPTION    VARCHAR      COMMENT 'Invoice line description'
) COMMENT = 'Supplier invoices against approved purchase orders (one row per invoice).';

INSERT INTO PO_INVOICES
WITH A AS (
  SELECT P.PO_ID, P.SUPPLIER_ID, P.PO_DATE, P.AMOUNT, P.DESCRIPTION, K.PK, K.CATEGORY, K.IS_GOODS, K.IS_CAPEX_PROJECT,
         CASE WHEN K.IS_GOODS THEN IFF({{BUILD_DB}}.GEN.U(K.PK || ':ninv') < 0.7, 1, 2)
              WHEN K.CATEGORY = 'Utilities & Energy' THEN 3 + IFF({{BUILD_DB}}.GEN.U(K.PK || ':ninv') < 0.5, 0, 1)
              ELSE 2 + FLOOR({{BUILD_DB}}.GEN.U(K.PK || ':ninv') * 3) END AS N_INV
  FROM PO_TRANSACTIONS P
  JOIN {{BUILD_DB}}.GEN.PO_KEYS K ON K.PO_ID = P.PO_ID
  WHERE P.STATUS = 'Approved'
), L AS (
  SELECT A.*, S.N AS K_IDX,
         0.7 + 0.6 * {{BUILD_DB}}.GEN.U(A.PK || ':w' || S.N) AS W,
         IFF(A.IS_GOODS,
             DATEADD(DAY, 5 + FLOOR({{BUILD_DB}}.GEN.U(A.PK || ':d' || S.N) * 25) + 30 * S.N, A.PO_DATE),
             DATEADD(DAY, 7 + FLOOR({{BUILD_DB}}.GEN.U(A.PK || ':d' || S.N) * 10) + 30 * S.N, A.PO_DATE)) AS INVOICE_DATE
  FROM A JOIN {{BUILD_DB}}.GEN.SEQ S ON S.N < A.N_INV
), AM AS (
  SELECT L.*,
         ROUND(L.AMOUNT * L.W / SUM(L.W) OVER (PARTITION BY L.PO_ID), 2) AS RAW_AMT,
         ROW_NUMBER() OVER (PARTITION BY L.PO_ID ORDER BY L.K_IDX DESC) AS REV_IDX
  FROM L
), FIN AS (
  SELECT AM.*,
         IFF(AM.REV_IDX = 1,
             AM.AMOUNT - COALESCE(SUM(IFF(AM.REV_IDX = 1, 0, AM.RAW_AMT)) OVER (PARTITION BY AM.PO_ID), 0),
             AM.RAW_AMT) AS INVOICE_AMOUNT,
         DATEADD(DAY, SP.PAYMENT_TERMS_DAYS, AM.INVOICE_DATE) AS DUE_DATE,
         S.COMPLIANCE_STATUS
  FROM AM
  JOIN {{BUILD_DB}}.GEN.SUPPLIER_PROFILE SP ON SP.SUPPLIER_ID = AM.SUPPLIER_ID
  JOIN SUPPLIERS S ON S.SUPPLIER_ID = AM.SUPPLIER_ID
), ST AS (
  SELECT FIN.*,
         DATEDIFF(DAY, FIN.DUE_DATE, '2026-10-31'::DATE) AS DPD,
         {{BUILD_DB}}.GEN.U(FIN.PK || ':pay' || FIN.K_IDX) AS R,
         IFF(FIN.COMPLIANCE_STATUS = 'Non-Compliant', 3, 1) AS HOLD_MULT
  FROM FIN
  WHERE FIN.INVOICE_DATE <= '2026-10-31'::DATE
)
SELECT
  'INV' || LPAD(ROW_NUMBER() OVER (ORDER BY INVOICE_DATE, PO_ID, K_IDX), 7, '0'),
  PO_ID, SUPPLIER_ID, INVOICE_DATE, DUE_DATE, INVOICE_AMOUNT,
  CASE
    WHEN DPD <= 0   THEN IFF(R < 0.12, 'Paid', 'Pending')
    WHEN DPD <= 30  THEN CASE WHEN R < 0.12 THEN 'Overdue' WHEN R < 0.12 + 0.02 * HOLD_MULT THEN 'On Hold' ELSE 'Paid' END
    WHEN DPD <= 120 THEN CASE WHEN R < 0.03 THEN 'Overdue' WHEN R < 0.03 + 0.01 * HOLD_MULT THEN 'On Hold' ELSE 'Paid' END
    ELSE CASE WHEN R < 0.004 THEN 'Overdue' WHEN R < 0.004 + 0.003 * HOLD_MULT THEN 'On Hold' ELSE 'Paid' END
  END,
  DESCRIPTION || ' (' || MONTHNAME(INVOICE_DATE) || ' ' || YEAR(INVOICE_DATE) || ')'
FROM ST;
