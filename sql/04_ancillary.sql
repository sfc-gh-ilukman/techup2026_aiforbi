-- =============================================================================
-- 04_ancillary.sql — uncurated "long tail" tables (build area)
-- CONTRACTS, SUPPLIER_ASSESSMENTS, ASSET_REGISTER, INCIDENT_LOG, PROCUREMENT_EMAILS
-- Depends on 01–03. As-at date 2026-10-31.
-- =============================================================================

USE ROLE {{ROLE}};
USE WAREHOUSE {{WH}};
USE SCHEMA {{BUILD_DB}}.PUBLIC;

-- =============================================================================
-- CONTRACTS
-- Each supplier has 3 x (states serviced) + 2 contract "series"; a series is a
-- chain of consecutive contracts from 2019–2022 onwards. Auto-renew series are
-- a single row whose END_DATE is the current term end.
-- =============================================================================
CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.CATEGORY_CONTRACT_TYPES AS
SELECT CATEGORY, CONTRACT_TYPE, ANNUAL_VALUE,
       ROW_NUMBER() OVER (PARTITION BY CATEGORY ORDER BY CONTRACT_TYPE) - 1 AS IDX,
       COUNT(*) OVER (PARTITION BY CATEGORY) AS N_TYPES
FROM VALUES
  ('Cleaning Services','Service Level Agreement',60000), ('Cleaning Services','Statement of Work',60000),
  ('Facilities Maintenance','Maintenance Agreement',70000), ('Facilities Maintenance','Statement of Work',70000),
  ('Fitness Equipment','Supply Agreement',120000), ('Fitness Equipment','Purchase Agreement',120000), ('Fitness Equipment','Lease Agreement',120000),
  ('Equipment Servicing','Maintenance Agreement',30000), ('Equipment Servicing','Service Level Agreement',30000),
  ('IT Services','Service Level Agreement',60000), ('IT Services','Statement of Work',60000),
  ('Software & SaaS','Licence Agreement',45000),
  ('Marketing & Advertising','Statement of Work',50000), ('Marketing & Advertising','Consultancy Agreement',50000),
  ('Security Services','Service Level Agreement',35000), ('Security Services','Maintenance Agreement',35000),
  ('Utilities & Energy','Supply Agreement',110000),
  ('Pool & Aquatic Services','Maintenance Agreement',40000), ('Pool & Aquatic Services','Supply Agreement',40000),
  ('HVAC Services','Maintenance Agreement',50000), ('HVAC Services','Service Level Agreement',50000),
  ('Professional Services','Consultancy Agreement',60000), ('Professional Services','Statement of Work',60000),
  ('Office Supplies','Supply Agreement',15000), ('Office Supplies','Purchase Agreement',15000),
  ('Catering & Nutrition','Supply Agreement',18000), ('Catering & Nutrition','Purchase Agreement',18000)
  AS V(CATEGORY, CONTRACT_TYPE, ANNUAL_VALUE);

CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.CONTRACT_SERIES AS
WITH SER AS (
  SELECT S.SUPPLIER_ID, S.CATEGORY, Q.N AS SERIES_IDX, (Q.N < 2) AS IS_MASTER,
         S.SUPPLIER_ID || ':ser' || Q.N AS SK
  FROM SUPPLIERS S
  JOIN {{BUILD_DB}}.GEN.SEQ Q ON Q.N < 3 * ARRAY_SIZE(S.SERVICE_REGIONS) + 2
)
SELECT SER.*,
  CASE WHEN {{BUILD_DB}}.GEN.U(SK || ':rt') < 0.40 THEN 'Annual'
       WHEN {{BUILD_DB}}.GEN.U(SK || ':rt') < 0.65 THEN 'Biennial'
       WHEN {{BUILD_DB}}.GEN.U(SK || ':rt') < 0.85 THEN 'Fixed Term'
       ELSE 'Auto-renew' END                                                         AS RENEWAL_TYPE,
  DATEADD(DAY, FLOOR({{BUILD_DB}}.GEN.U(SK || ':start') * 1095), '2019-07-01'::DATE) AS SERIES_START,
  {{BUILD_DB}}.GEN.U(SK || ':disc') < 0.15                                     AS DISCONTINUED,
  {{BUILD_DB}}.GEN.U(SK || ':disc_at')                                         AS U_DISC_AT,
  {{BUILD_DB}}.GEN.U(SK || ':type')                                            AS U_TYPE
FROM SER;

CREATE OR REPLACE TABLE CONTRACTS (
  CONTRACT_ID     VARCHAR      COMMENT 'Primary key',
  SUPPLIER_ID     VARCHAR      COMMENT 'Contracted supplier. Joins to SUPPLIERS.SUPPLIER_ID',
  CONTRACT_TYPE   VARCHAR      COMMENT 'Master Services Agreement, Framework Agreement, Statement of Work, Service Level Agreement, Supply Agreement, Maintenance Agreement, Licence Agreement, Consultancy Agreement, Lease Agreement, Purchase Agreement',
  START_DATE      DATE         COMMENT 'Contract (current term) start date',
  END_DATE        DATE         COMMENT 'Contract (current term) end date. For Auto-renew contracts this is the end of the current term',
  CONTRACT_VALUE  NUMBER(12,2) COMMENT 'Total contract value for the term, AUD',
  CONTRACT_STATUS VARCHAR      COMMENT 'Active / Expired / Under Renewal (as at 2026-10-31)',
  RENEWAL_TYPE    VARCHAR      COMMENT 'Annual / Biennial / Fixed Term / Auto-renew'
);

INSERT INTO CONTRACTS
WITH T AS (
  SELECT CS.*, DECODE(CS.RENEWAL_TYPE, 'Annual', 12, 'Biennial', 24, 'Fixed Term', 36, 12) AS TERM_M,
         IFF(CS.IS_MASTER, IFF(CS.U_TYPE < 0.6, 'Master Services Agreement', 'Framework Agreement'), CT.CONTRACT_TYPE) AS CONTRACT_TYPE,
         CT.ANNUAL_VALUE * IFF(CS.IS_MASTER, 3, 1) AS ANNUAL_VALUE
  FROM {{BUILD_DB}}.GEN.CONTRACT_SERIES CS
  JOIN {{BUILD_DB}}.GEN.CATEGORY_CONTRACT_TYPES CT
    ON CT.CATEGORY = CS.CATEGORY AND CT.IDX = FLOOR(CS.U_TYPE * CT.N_TYPES)
), CHAIN AS (
  -- consecutive terms for non auto-renew series
  SELECT T.*, Q.N AS K_IDX,
         DATEADD(MONTH, Q.N * T.TERM_M, T.SERIES_START)                          AS START_DATE,
         DATEADD(DAY, -1, DATEADD(MONTH, (Q.N + 1) * T.TERM_M, T.SERIES_START))  AS END_DATE
  FROM T JOIN {{BUILD_DB}}.GEN.SEQ Q ON Q.N < 12
  WHERE T.RENEWAL_TYPE <> 'Auto-renew'
    AND DATEADD(MONTH, Q.N * T.TERM_M, T.SERIES_START) <= '2026-10-31'::DATE
), CHAIN_CUT AS (
  SELECT CHAIN.*, COUNT(*) OVER (PARTITION BY SK) AS N_TOTAL
  FROM CHAIN
), AUTO AS (
  SELECT T.*, 0 AS K_IDX, T.SERIES_START AS START_DATE,
         IFF(T.DISCONTINUED,
             DATEADD(DAY, -1, DATEADD(YEAR, 1 + FLOOR(T.U_DISC_AT * GREATEST(1, FLOOR(DATEDIFF(DAY, T.SERIES_START, '2026-10-31'::DATE) / 365.25))), T.SERIES_START)),
             DATEADD(DAY, -1, DATEADD(YEAR, FLOOR(DATEDIFF(DAY, T.SERIES_START, '2026-10-31'::DATE) / 365.25) + 1, T.SERIES_START))) AS END_DATE,
         1 AS N_TOTAL
  FROM T WHERE T.RENEWAL_TYPE = 'Auto-renew'
), ALLC AS (
  SELECT SUPPLIER_ID, SK, K_IDX, CONTRACT_TYPE, RENEWAL_TYPE, START_DATE, END_DATE, TERM_M, ANNUAL_VALUE
  FROM CHAIN_CUT
  WHERE K_IDX < IFF(DISCONTINUED, GREATEST(1, FLOOR(N_TOTAL * (0.3 + 0.5 * U_DISC_AT))), N_TOTAL)
  UNION ALL
  SELECT SUPPLIER_ID, SK, K_IDX, CONTRACT_TYPE, RENEWAL_TYPE, START_DATE, END_DATE, 12, ANNUAL_VALUE
  FROM AUTO
)
SELECT
  'CT' || LPAD(ROW_NUMBER() OVER (ORDER BY START_DATE, SUPPLIER_ID, SK, K_IDX), 5, '0'),
  SUPPLIER_ID, CONTRACT_TYPE, START_DATE, END_DATE,
  ROUND(ANNUAL_VALUE * IFF(RENEWAL_TYPE = 'Auto-renew', 1, TERM_M / 12)
        * EXP(0.45 * {{BUILD_DB}}.GEN.N(SK || ':val' || K_IDX)), -2),
  CASE WHEN END_DATE < '2026-10-31'::DATE THEN 'Expired'
       WHEN RENEWAL_TYPE <> 'Auto-renew'
            AND END_DATE <= DATEADD(DAY, 120, '2026-10-31'::DATE)
            AND {{BUILD_DB}}.GEN.U(SK || ':ur' || K_IDX) < 0.35 THEN 'Under Renewal'
       ELSE 'Active' END,
  RENEWAL_TYPE
FROM ALLC;

-- =============================================================================
-- SUPPLIER_ASSESSMENTS
-- Half-yearly, per supplier x centre where the supplier had >= 8 approved POs
-- at that centre in the half-year. Completed periods only (H1-FY2023..H2-FY2026).
-- =============================================================================
CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.PERIODS AS
SELECT PERIOD, START_DATE::DATE AS START_DATE, END_DATE::DATE AS END_DATE, ORD
FROM VALUES
  ('H1-FY2023','2022-07-01','2022-12-31',1), ('H2-FY2023','2023-01-01','2023-06-30',2),
  ('H1-FY2024','2023-07-01','2023-12-31',3), ('H2-FY2024','2024-01-01','2024-06-30',4),
  ('H1-FY2025','2024-07-01','2024-12-31',5), ('H2-FY2025','2025-01-01','2025-06-30',6),
  ('H1-FY2026','2025-07-01','2025-12-31',7), ('H2-FY2026','2026-01-01','2026-06-30',8)
  AS V(PERIOD, START_DATE, END_DATE, ORD);

CREATE OR REPLACE TABLE SUPPLIER_ASSESSMENTS (
  ASSESSMENT_ID         VARCHAR     COMMENT 'Primary key',
  SUPPLIER_ID           VARCHAR     COMMENT 'Assessed supplier. Joins to SUPPLIERS.SUPPLIER_ID',
  PROFIT_CENTRE_ID      VARCHAR     COMMENT 'Centre that performed the assessment. Joins to PROFIT_CENTRES.PROFIT_CENTRE_ID',
  ASSESSMENT_PERIOD     VARCHAR     COMMENT 'Half-year period, e.g. H1-FY2026 (H1 = Jul–Dec, H2 = Jan–Jun of the financial year)',
  QUALITY_SCORE         NUMBER(3,2) COMMENT 'Quality of goods/services, 1.00–5.00',
  TIMELINESS_SCORE      NUMBER(3,2) COMMENT 'On-time delivery/response, 1.00–5.00',
  COMMUNICATION_SCORE   NUMBER(3,2) COMMENT 'Communication and responsiveness, 1.00–5.00',
  VALUE_FOR_MONEY_SCORE NUMBER(3,2) COMMENT 'Value for money, 1.00–5.00',
  OVERALL_SCORE         NUMBER(3,2) COMMENT 'Mean of the four scores',
  RECOMMENDATION        VARCHAR     COMMENT 'Assessor recommendation: Preferred / Approved / Conditional / Not Recommended',
  ASSESSOR_COMMENTS     VARCHAR     COMMENT 'Free-text assessor comments'
);

INSERT INTO SUPPLIER_ASSESSMENTS
WITH ACT AS (
  SELECT P.SUPPLIER_ID, P.PROFIT_CENTRE_ID, PR.PERIOD, PR.ORD
  FROM PO_TRANSACTIONS P
  JOIN {{BUILD_DB}}.GEN.PERIODS PR ON P.PO_DATE BETWEEN PR.START_DATE AND PR.END_DATE
  WHERE P.STATUS = 'Approved'
  GROUP BY 1, 2, 3, 4
  HAVING COUNT(*) >= 8
), SC AS (
  SELECT A.*, SP.BASE_QUALITY,
         A.SUPPLIER_ID || ':' || A.PROFIT_CENTRE_ID || ':' || A.PERIOD AS AK,
         0.10 * {{BUILD_DB}}.GEN.N(A.SUPPLIER_ID || ':' || A.PERIOD || ':drift')
       + 0.22 * {{BUILD_DB}}.GEN.N(A.SUPPLIER_ID || ':' || A.PROFIT_CENTRE_ID || ':' || A.PERIOD || ':cp') AS SHARED
  FROM ACT A JOIN {{BUILD_DB}}.GEN.SUPPLIER_PROFILE SP ON SP.SUPPLIER_ID = A.SUPPLIER_ID
), D AS (
  SELECT SC.*,
    LEAST(5, GREATEST(1, ROUND(BASE_QUALITY + 0.15 * {{BUILD_DB}}.GEN.N(SUPPLIER_ID || ':q') + SHARED + 0.18 * {{BUILD_DB}}.GEN.N(AK || ':q'), 2))) AS Q_S,
    LEAST(5, GREATEST(1, ROUND(BASE_QUALITY + 0.15 * {{BUILD_DB}}.GEN.N(SUPPLIER_ID || ':t') + SHARED + 0.18 * {{BUILD_DB}}.GEN.N(AK || ':t'), 2))) AS T_S,
    LEAST(5, GREATEST(1, ROUND(BASE_QUALITY + 0.15 * {{BUILD_DB}}.GEN.N(SUPPLIER_ID || ':c') + SHARED + 0.18 * {{BUILD_DB}}.GEN.N(AK || ':c'), 2))) AS C_S,
    LEAST(5, GREATEST(1, ROUND(BASE_QUALITY + 0.15 * {{BUILD_DB}}.GEN.N(SUPPLIER_ID || ':v') + SHARED + 0.18 * {{BUILD_DB}}.GEN.N(AK || ':v'), 2))) AS V_S
  FROM SC
), O AS (
  SELECT D.*, ROUND((Q_S + T_S + C_S + V_S) / 4, 2) AS OVERALL,
         ROUND((Q_S + T_S + C_S + V_S) / 4, 2) + 0.12 * {{BUILD_DB}}.GEN.N(AK || ':rec') AS REC_SCORE,
         {{BUILD_DB}}.GEN.U(AK || ':cmt') AS U_CMT
  FROM D
)
SELECT
  'SA' || LPAD(ROW_NUMBER() OVER (ORDER BY ORD, SUPPLIER_ID, PROFIT_CENTRE_ID), 5, '0'),
  SUPPLIER_ID, PROFIT_CENTRE_ID, PERIOD, Q_S, T_S, C_S, V_S, OVERALL,
  CASE WHEN REC_SCORE >= 4.20 THEN 'Preferred'
       WHEN REC_SCORE >= 3.40 THEN 'Approved'
       WHEN REC_SCORE >= 2.60 THEN 'Conditional'
       ELSE 'Not Recommended' END,
  CASE
    WHEN OVERALL >= 4.2 THEN DECODE(FLOOR(U_CMT * 4), 0, 'Consistently excellent service. Proactive and easy to work with.',
                                                        1, 'High quality work delivered on schedule. Strong partner for the centre.',
                                                        2, 'Very responsive team, issues resolved quickly.',
                                                           'Excellent value and reliability this period.')
    WHEN OVERALL >= 3.5 THEN DECODE(FLOOR(U_CMT * 4), 0, 'Solid performance overall with minor delays.',
                                                        1, 'Good quality. Some follow-up needed on scheduling.',
                                                        2, 'Meets expectations. Invoicing occasionally needs correction.',
                                                           'Reliable supplier, no major issues raised.')
    WHEN OVERALL >= 2.8 THEN DECODE(FLOOR(U_CMT * 4), 0, 'Several missed service windows this period. Monitoring closely.',
                                                        1, 'Quality inconsistent across visits. Raised with account manager.',
                                                        2, 'Slow to respond to callouts. Improvement plan discussed.',
                                                           'Pricing above market for the level of service received.')
    ELSE DECODE(FLOOR(U_CMT * 4), 0, 'Repeated quality failures. Escalated to procurement.',
                                  1, 'Service levels well below contract. Considering alternatives.',
                                  2, 'Poor communication and frequent no-shows.',
                                     'Significant rework required. Not meeting agreed standards.')
  END
FROM O;

-- =============================================================================
-- ASSET_REGISTER
-- =============================================================================
CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.ASSET_PROFILE AS
SELECT * FROM VALUES
  -- category, n_large, n_medium, n_small, pool_only, cost_median, warranty_supplier_category, names (pipe-separated)
  ('Cardio',                 180, 120, 60, FALSE,  9500, 'Fitness Equipment',      'Treadmill|Elliptical Cross Trainer|Rowing Machine|Upright Bike|Stair Climber|Air Bike'),
  ('Strength',               160, 100, 55, FALSE,  6500, 'Fitness Equipment',      'Leg Press|Lat Pulldown|Chest Press|Cable Crossover|Smith Machine|Hack Squat'),
  ('Free Weights',           220, 140, 80, FALSE,   450, 'Fitness Equipment',      'Dumbbell Set|Olympic Barbell|Weight Plate Set|Kettlebell Set|Squat Rack|Adjustable Bench'),
  ('Studio & Group Fitness', 120,  80, 40, FALSE,   900, 'Fitness Equipment',      'Studio Spin Bike|Pilates Reformer|Step Platform Set|Boxing Bag|Yoga Equipment Set'),
  ('Pool',                    60,  40,  0, TRUE,   7500, 'Pool & Aquatic Services','Pool Pump|Sand Filter|Chlorinator|Pool Heater|Lane Rope Set|Pool Hoist'),
  ('HVAC',                    35,  25, 12, FALSE, 28000, 'HVAC Services',          'Rooftop AC Unit|Air Handling Unit|Exhaust Fan|Split System AC|Chiller'),
  ('IT',                      90,  60, 30, FALSE,  1800, 'IT Services',            'Reception PC|Staff Laptop|Network Switch|Wireless Access Point|POS Terminal|Server'),
  ('Fitout',                  70,  45, 25, FALSE, 15000, 'Facilities Maintenance', 'Change Room Fitout|Reception Desk Fitout|Gym Flooring|Lighting System|Locker Bank'),
  ('Audio Visual',            40,  25, 12, FALSE,  2500, 'IT Services',            'Studio Speaker System|Gym Floor TV Screen|Projector|Microphone System'),
  ('Security & Access',       30,  20, 10, FALSE,  3000, 'Security Services',      'CCTV Camera|Access Turnstile|Door Access Controller|Alarm Panel'),
  ('Furniture',               60,  40, 20, FALSE,   900, NULL,                     'Lounge Seating|Staff Desk|Cafe Table Set|Storage Shelving'),
  ('Laundry & Cleaning',      25,  15,  8, FALSE,  3500, NULL,                     'Commercial Washer|Commercial Dryer|Floor Scrubber|Industrial Vacuum')
  AS V(ASSET_CATEGORY, N_LARGE, N_MEDIUM, N_SMALL, POOL_ONLY, COST_MEDIAN, WARRANTY_CATEGORY, NAMES);

CREATE OR REPLACE TABLE ASSET_REGISTER (
  ASSET_ID             VARCHAR      COMMENT 'Primary key. Referenced by INCIDENT_LOG.RELATED_ASSET_ID',
  PROFIT_CENTRE_ID     VARCHAR      COMMENT 'Centre where the asset is located. Joins to PROFIT_CENTRES.PROFIT_CENTRE_ID',
  ASSET_CATEGORY       VARCHAR      COMMENT 'Cardio, Strength, Free Weights, Studio & Group Fitness, Pool, HVAC, IT, Fitout, Audio Visual, Security & Access, Furniture, Laundry & Cleaning',
  ASSET_NAME           VARCHAR      COMMENT 'Asset description',
  PURCHASE_DATE        DATE         COMMENT 'Date the asset was purchased',
  PURCHASE_COST        NUMBER(12,2) COMMENT 'Purchase cost in AUD',
  ASSET_STATUS         VARCHAR      COMMENT 'Active / Needs Maintenance / Decommissioned / Disposed',
  WARRANTY_SUPPLIER_ID VARCHAR      COMMENT 'Supplier providing warranty cover, if any. Joins to SUPPLIERS.SUPPLIER_ID (NULL when no warranty)'
);

INSERT INTO ASSET_REGISTER
WITH A AS (
  SELECT P.PROFIT_CENTRE_ID, P.STATE, AP.*, Q.N, P.PROFIT_CENTRE_ID || ':' || AP.ASSET_CATEGORY || ':' || Q.N AS AK
  FROM PROFIT_CENTRES P
  CROSS JOIN {{BUILD_DB}}.GEN.ASSET_PROFILE AP
  JOIN {{BUILD_DB}}.GEN.SEQ Q
    ON Q.N < ROUND(0.956 * DECODE(P.CENTRE_SIZE, 'large', AP.N_LARGE, 'medium', AP.N_MEDIUM, AP.N_SMALL))
  WHERE NOT AP.POOL_ONLY OR P.HAS_POOL
), B AS (
  SELECT A.*,
         DATEADD(DAY, -FLOOR(POWER({{BUILD_DB}}.GEN.U(AK || ':age'), 1.3) * 4700), '2026-10-31'::DATE) AS PURCHASE_DATE,
         {{BUILD_DB}}.GEN.U(AK || ':st') AS U_ST,
         {{BUILD_DB}}.GEN.U(AK || ':war') AS U_WAR,
         {{BUILD_DB}}.GEN.U(AK || ':ws') AS U_WS,
         SPLIT(A.NAMES, '|') AS NAME_ARR,
         {{BUILD_DB}}.GEN.U(AK || ':nm') AS U_NM
  FROM A
), C AS (
  SELECT B.*, DATEDIFF(DAY, B.PURCHASE_DATE, '2026-10-31'::DATE) / 365.25 AS AGE_Y
  FROM B
), W AS (
  -- warranty supplier: same category group, services the centre's state
  SELECT C.AK, CS.SUPPLIER_ID
  FROM C
  JOIN {{BUILD_DB}}.GEN.CENTRE_SUPPLIER CS
    ON CS.PROFIT_CENTRE_ID = C.PROFIT_CENTRE_ID AND CS.CATEGORY = C.WARRANTY_CATEGORY
  WHERE C.WARRANTY_CATEGORY IS NOT NULL AND C.AGE_Y < 5 AND C.U_WAR < 0.80
  QUALIFY ROW_NUMBER() OVER (PARTITION BY C.AK ORDER BY HASH(C.AK, CS.SUPPLIER_ID)) = 1
)
SELECT
  'AST' || LPAD(ROW_NUMBER() OVER (ORDER BY C.PURCHASE_DATE, C.AK), 6, '0'),
  C.PROFIT_CENTRE_ID, C.ASSET_CATEGORY,
  GET(C.NAME_ARR, FLOOR(C.U_NM * ARRAY_SIZE(C.NAME_ARR))::INT)::STRING,
  C.PURCHASE_DATE,
  ROUND(C.COST_MEDIAN * EXP(0.45 * {{BUILD_DB}}.GEN.N(C.AK || ':cost')) * POWER(1.025, -C.AGE_Y), 2),
  CASE WHEN C.AGE_Y < 3  THEN IFF(C.U_ST < 0.95, 'Active', 'Needs Maintenance')
       WHEN C.AGE_Y < 7  THEN CASE WHEN C.U_ST < 0.80 THEN 'Active' WHEN C.U_ST < 0.95 THEN 'Needs Maintenance' ELSE 'Decommissioned' END
       WHEN C.AGE_Y < 10 THEN CASE WHEN C.U_ST < 0.55 THEN 'Active' WHEN C.U_ST < 0.75 THEN 'Needs Maintenance' WHEN C.U_ST < 0.90 THEN 'Decommissioned' ELSE 'Disposed' END
       ELSE CASE WHEN C.U_ST < 0.25 THEN 'Active' WHEN C.U_ST < 0.40 THEN 'Needs Maintenance' WHEN C.U_ST < 0.65 THEN 'Decommissioned' ELSE 'Disposed' END
  END,
  W.SUPPLIER_ID
FROM C LEFT JOIN W ON W.AK = C.AK;

-- =============================================================================
-- INCIDENT_LOG
-- ~46.3 incidents per size-unit per month (large 1.6, medium 1.0, small 0.6).
-- RELATED_PO_ID: an approved PO at the same centre, matching supplier category,
-- raised in the 90 days before the incident. RELATED_ASSET_ID: an asset at the
-- same centre in a matching category, purchased before the incident.
-- =============================================================================
CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.INCIDENT_TYPES AS
SELECT * FROM VALUES
  ('Equipment Breakdown','Maintenance',14,FALSE,'STD',0.55,'Equipment Servicing','Fitness Equipment',0.7,0.90,'Cardio|Strength|Free Weights|Studio & Group Fitness'),
  ('HVAC Failure','Maintenance',4,FALSE,'STD',0.60,'HVAC Services',NULL,1.0,0.90,'HVAC'),
  ('Plumbing Leak','Maintenance',5,FALSE,'STD',0.60,'Facilities Maintenance',NULL,1.0,0.20,'Fitout'),
  ('Electrical Fault','Maintenance',4,FALSE,'STD',0.55,'Facilities Maintenance',NULL,1.0,0.40,'Fitout'),
  ('Pool Plant Failure','Maintenance',3,TRUE,'STD',0.60,'Pool & Aquatic Services',NULL,1.0,0.90,'Pool'),
  ('Member Injury','OH&S',5,FALSE,'INJ',0.10,'Equipment Servicing',NULL,1.0,0.50,'Cardio|Strength|Free Weights'),
  ('Staff Injury','OH&S',2,FALSE,'INJ',0.00,NULL,NULL,1.0,0.20,'Laundry & Cleaning|Furniture'),
  ('Slip, Trip or Fall','OH&S',5,FALSE,'INJ',0.20,'Cleaning Services',NULL,1.0,0.10,'Fitout'),
  ('Chemical Exposure','OH&S',1,TRUE,'INJ',0.50,'Pool & Aquatic Services',NULL,1.0,0.30,'Pool'),
  ('Member Complaint','Customer',14,FALSE,'CUS',0.00,NULL,NULL,1.0,0.10,'Cardio|Strength|Free Weights|Studio & Group Fitness'),
  ('Billing Dispute','Customer',8,FALSE,'CUS',0.15,'Software & SaaS',NULL,1.0,0.00,NULL),
  ('Class Cancellation','Customer',6,FALSE,'CUS',0.00,NULL,NULL,1.0,0.10,'Audio Visual|Studio & Group Fitness'),
  ('Facility Cleanliness Complaint','Customer',6,FALSE,'CUS',0.45,'Cleaning Services',NULL,1.0,0.05,'Laundry & Cleaning'),
  ('Theft','Security',4,FALSE,'STD',0.10,'Security Services',NULL,1.0,0.10,'Security & Access'),
  ('Unauthorised Access','Security',2,FALSE,'STD',0.30,'Security Services',NULL,1.0,0.50,'Security & Access'),
  ('Vandalism','Security',2,FALSE,'STD',0.00,NULL,NULL,1.0,0.40,'Fitout|Furniture'),
  ('Alarm Activation','Security',4,FALSE,'STD',0.35,'Security Services',NULL,1.0,0.60,'Security & Access'),
  ('System Outage','IT',3,FALSE,'STD',0.50,'IT Services','Software & SaaS',0.6,0.60,'IT'),
  ('Network Failure','IT',2,FALSE,'STD',0.60,'IT Services',NULL,1.0,0.80,'IT'),
  ('Door Access System Fault','IT',2,FALSE,'STD',0.40,'Security Services','IT Services',0.5,0.90,'Security & Access')
  AS V(INCIDENT_TYPE, INCIDENT_CATEGORY, WEIGHT, POOL_ONLY, SEV_PROFILE, PO_PROB, PO_CAT1, PO_CAT2, PO_CAT1_SHARE, ASSET_PROB, ASSET_CATS);

CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.INCIDENT_TYPE_CUM AS
WITH F AS (
  SELECT HP.HAS_POOL, T.*
  FROM (SELECT TRUE AS HAS_POOL UNION ALL SELECT FALSE) HP
  JOIN {{BUILD_DB}}.GEN.INCIDENT_TYPES T ON NOT T.POOL_ONLY OR HP.HAS_POOL
)
SELECT F.*,
  COALESCE(SUM(WEIGHT) OVER (PARTITION BY HAS_POOL ORDER BY INCIDENT_TYPE ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)
    / SUM(WEIGHT) OVER (PARTITION BY HAS_POOL) AS CUM_LO,
  SUM(WEIGHT) OVER (PARTITION BY HAS_POOL ORDER BY INCIDENT_TYPE ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
    / SUM(WEIGHT) OVER (PARTITION BY HAS_POOL) AS CUM_HI
FROM F;

CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.INC_GEN AS
WITH CM AS (
  SELECT P.PROFIT_CENTRE_ID, P.HAS_POOL, M.MONTH_START, M.DAYS_IN_MONTH, M.MONTH_IDX,
         ROUND(46.3 * DECODE(P.CENTRE_SIZE, 'large', 1.6, 'medium', 1.0, 0.6)
               * (1 + 0.10 * {{BUILD_DB}}.GEN.N(P.PROFIT_CENTRE_ID || ':' || M.MONTH_IDX || ':inc'))) AS N_INC
  FROM PROFIT_CENTRES P CROSS JOIN {{BUILD_DB}}.GEN.MONTHS M
), B AS (
  SELECT CM.*, 'I:' || CM.PROFIT_CENTRE_ID || ':' || CM.MONTH_IDX || ':' || Q.N AS IK
  FROM CM JOIN {{BUILD_DB}}.GEN.SEQ Q ON Q.N < CM.N_INC
), R AS (
  SELECT B.*,
         DATEADD(DAY, FLOOR({{BUILD_DB}}.GEN.U(IK || ':day') * DAYS_IN_MONTH), MONTH_START) AS INCIDENT_DATE,
         {{BUILD_DB}}.GEN.U(IK || ':type') AS U_TYPE
  FROM B
)
SELECT R.IK, R.PROFIT_CENTRE_ID, R.INCIDENT_DATE, T.INCIDENT_TYPE, T.INCIDENT_CATEGORY, T.SEV_PROFILE,
       (T.PO_CAT1 IS NOT NULL AND {{BUILD_DB}}.GEN.U(R.IK || ':po') < 0.75 * T.PO_PROB) AS WANT_PO,
       IFF(T.PO_CAT2 IS NOT NULL AND {{BUILD_DB}}.GEN.U(R.IK || ':pocat') >= T.PO_CAT1_SHARE, T.PO_CAT2, T.PO_CAT1) AS PO_CATEGORY,
       (T.ASSET_CATS IS NOT NULL AND {{BUILD_DB}}.GEN.U(R.IK || ':asset') < T.ASSET_PROB) AS WANT_ASSET,
       GET(SPLIT(T.ASSET_CATS, '|'), FLOOR({{BUILD_DB}}.GEN.U(R.IK || ':acat') * ARRAY_SIZE(SPLIT(T.ASSET_CATS, '|')))::INT)::STRING AS ASSET_CATEGORY,
       {{BUILD_DB}}.GEN.U(R.IK || ':sev') AS U_SEV,
       {{BUILD_DB}}.GEN.U(R.IK || ':status') AS U_STATUS
FROM R
JOIN {{BUILD_DB}}.GEN.INCIDENT_TYPE_CUM T
  ON T.HAS_POOL = R.HAS_POOL AND R.U_TYPE >= T.CUM_LO AND R.U_TYPE < IFF(T.CUM_HI > 0.9999999, 2, T.CUM_HI);

CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.INC_PO AS
SELECT I.IK, P.PO_ID
FROM {{BUILD_DB}}.GEN.INC_GEN I
JOIN {{BUILD_DB}}.GEN.PO_GEN P
  ON P.PROFIT_CENTRE_ID = I.PROFIT_CENTRE_ID
 AND P.CATEGORY = I.PO_CATEGORY
 AND P.STATUS = 'Approved'
 AND P.PO_DATE BETWEEN DATEADD(DAY, -90, I.INCIDENT_DATE) AND I.INCIDENT_DATE
WHERE I.WANT_PO
QUALIFY ROW_NUMBER() OVER (PARTITION BY I.IK ORDER BY HASH(I.IK, P.PO_ID)) = 1;

CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.INC_ASSET AS
SELECT I.IK, A.ASSET_ID
FROM {{BUILD_DB}}.GEN.INC_GEN I
JOIN ASSET_REGISTER A
  ON A.PROFIT_CENTRE_ID = I.PROFIT_CENTRE_ID
 AND A.ASSET_CATEGORY = I.ASSET_CATEGORY
 AND A.PURCHASE_DATE <= I.INCIDENT_DATE
WHERE I.WANT_ASSET
QUALIFY ROW_NUMBER() OVER (PARTITION BY I.IK ORDER BY HASH(I.IK, A.ASSET_ID)) = 1;

CREATE OR REPLACE TABLE INCIDENT_LOG (
  INCIDENT_ID       VARCHAR COMMENT 'Primary key',
  PROFIT_CENTRE_ID  VARCHAR COMMENT 'Centre where the incident occurred. Joins to PROFIT_CENTRES.PROFIT_CENTRE_ID',
  INCIDENT_DATE     DATE    COMMENT 'Date the incident occurred (Jul 2022 – Oct 2026)',
  INCIDENT_TYPE     VARCHAR COMMENT 'One of 20 incident types, e.g. Equipment Breakdown, HVAC Failure, Member Injury, Theft, System Outage',
  INCIDENT_CATEGORY VARCHAR COMMENT 'Maintenance / OH&S / Customer / Security / IT',
  SEVERITY          VARCHAR COMMENT 'Critical / High / Medium / Low',
  STATUS            VARCHAR COMMENT 'Open / In Progress / Resolved / Closed (as at 2026-10-31)',
  RELATED_PO_ID     VARCHAR COMMENT 'Purchase order for the supplier work related to the incident, if any. Joins to PO_TRANSACTIONS.PO_ID; the PO''s SUPPLIER_ID identifies the supplier involved',
  RELATED_ASSET_ID  VARCHAR COMMENT 'Asset involved in the incident, if any. Joins to ASSET_REGISTER.ASSET_ID'
);

INSERT INTO INCIDENT_LOG
WITH J AS (
  SELECT G.*, IP.PO_ID, IA.ASSET_ID, DATEDIFF(DAY, G.INCIDENT_DATE, '2026-10-31'::DATE) AS AGE_D
  FROM {{BUILD_DB}}.GEN.INC_GEN G
  LEFT JOIN {{BUILD_DB}}.GEN.INC_PO IP ON IP.IK = G.IK
  LEFT JOIN {{BUILD_DB}}.GEN.INC_ASSET IA ON IA.IK = G.IK
)
SELECT
  'INC' || LPAD(ROW_NUMBER() OVER (ORDER BY INCIDENT_DATE, IK), 6, '0'),
  PROFIT_CENTRE_ID, INCIDENT_DATE, INCIDENT_TYPE, INCIDENT_CATEGORY,
  CASE
    WHEN PO_ID IS NOT NULL THEN CASE WHEN U_SEV < 0.005 THEN 'Critical' WHEN U_SEV < 0.03 THEN 'High' WHEN U_SEV < 0.40 THEN 'Medium' ELSE 'Low' END
    WHEN SEV_PROFILE = 'INJ' THEN CASE WHEN U_SEV < 0.08 THEN 'Critical' WHEN U_SEV < 0.33 THEN 'High' WHEN U_SEV < 0.73 THEN 'Medium' ELSE 'Low' END
    WHEN SEV_PROFILE = 'CUS' THEN CASE WHEN U_SEV < 0.05 THEN 'High' WHEN U_SEV < 0.40 THEN 'Medium' ELSE 'Low' END
    ELSE CASE WHEN U_SEV < 0.03 THEN 'Critical' WHEN U_SEV < 0.15 THEN 'High' WHEN U_SEV < 0.50 THEN 'Medium' ELSE 'Low' END
  END,
  CASE
    WHEN AGE_D < 14 THEN CASE WHEN U_STATUS < 0.40 THEN 'Open' WHEN U_STATUS < 0.80 THEN 'In Progress' ELSE 'Resolved' END
    WHEN AGE_D < 60 THEN CASE WHEN U_STATUS < 0.05 THEN 'Open' WHEN U_STATUS < 0.20 THEN 'In Progress' WHEN U_STATUS < 0.70 THEN 'Resolved' ELSE 'Closed' END
    ELSE IFF(U_STATUS < 0.15, 'Resolved', 'Closed')
  END,
  PO_ID, ASSET_ID
FROM J;

-- =============================================================================
-- PROCUREMENT_EMAILS (metadata only, sent from buyer mailboxes)
-- Threads anchored on POs, invoices, contracts and supplier compliance.
-- =============================================================================
CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.EMAIL_THREADS AS
WITH PO_T AS (
  SELECT 'PO' AS KIND, P.PO_ID AS REF_ID, P.PO_ID, NULL::VARCHAR AS INVOICE_ID, P.SUPPLIER_ID, P.BUYER_ID,
         P.PROFIT_CENTRE_ID, DATEADD(DAY, -3, P.PO_DATE) AS ANCHOR_DATE, P.STATUS AS REF_STATUS, P.AMOUNT
  FROM PO_TRANSACTIONS P
  WHERE {{BUILD_DB}}.GEN.U(P.PO_ID || ':thr') < 0.105
), INV_T AS (
  SELECT 'INV', I.INVOICE_ID, I.PO_ID, I.INVOICE_ID, I.SUPPLIER_ID, P.BUYER_ID, P.PROFIT_CENTRE_ID,
         IFF(I.PAYMENT_STATUS IN ('Overdue', 'On Hold'), DATEADD(DAY, -10, I.DUE_DATE), I.INVOICE_DATE),
         I.PAYMENT_STATUS, I.INVOICE_AMOUNT
  FROM PO_INVOICES I JOIN PO_TRANSACTIONS P ON P.PO_ID = I.PO_ID
  WHERE I.PAYMENT_STATUS IN ('Overdue', 'On Hold') OR {{BUILD_DB}}.GEN.U(I.INVOICE_ID || ':thr') < 0.0075
), SUP_BUYER AS (
  -- a buyer from a state the supplier services (prefer Senior Buyers)
  SELECT S.SUPPLIER_ID, B.BUYER_ID, B.HOME_CENTRE_ID,
         ROW_NUMBER() OVER (PARTITION BY S.SUPPLIER_ID ORDER BY IFF(B.ROLE_TITLE = 'Senior Buyer', 0, 1), HASH(S.SUPPLIER_ID, B.BUYER_ID)) AS RN
  FROM SUPPLIERS S
  JOIN PROFIT_CENTRES P ON ARRAY_CONTAINS(P.STATE::VARIANT, S.SERVICE_REGIONS)
  JOIN BUYERS B ON B.HOME_CENTRE_ID = P.PROFIT_CENTRE_ID
), CON_T AS (
  SELECT 'CON', C.CONTRACT_ID, NULL, NULL, C.SUPPLIER_ID, SB.BUYER_ID, SB.HOME_CENTRE_ID,
         DATEADD(DAY, -60, C.END_DATE), C.CONTRACT_STATUS, C.CONTRACT_VALUE
  FROM CONTRACTS C
  JOIN SUP_BUYER SB ON SB.SUPPLIER_ID = C.SUPPLIER_ID AND SB.RN = 1 + MOD(ABS(HASH(C.CONTRACT_ID)), 2)
  WHERE DATEADD(DAY, -60, C.END_DATE) BETWEEN '2022-07-01'::DATE AND '2026-10-31'::DATE
    AND {{BUILD_DB}}.GEN.U(C.CONTRACT_ID || ':thr') < 0.6
), CMP_T AS (
  SELECT 'CMP', S.SUPPLIER_ID || ':Q' || Q.N, NULL, NULL, S.SUPPLIER_ID, SB.BUYER_ID, SB.HOME_CENTRE_ID,
         DATEADD(DAY, FLOOR({{BUILD_DB}}.GEN.U(S.SUPPLIER_ID || ':cmpd' || Q.N) * 80), DATEADD(MONTH, 3 * Q.N, '2022-07-01'::DATE)),
         S.COMPLIANCE_STATUS, NULL
  FROM SUPPLIERS S
  JOIN {{BUILD_DB}}.GEN.SEQ Q ON Q.N < 17
  JOIN SUP_BUYER SB ON SB.SUPPLIER_ID = S.SUPPLIER_ID AND SB.RN = 1
  WHERE {{BUILD_DB}}.GEN.U(S.SUPPLIER_ID || ':cmp' || Q.N) <
        DECODE(S.COMPLIANCE_STATUS, 'Non-Compliant', 1.0, 'Under Review', 0.5, 0.05)
)
SELECT ROW_NUMBER() OVER (ORDER BY ANCHOR_DATE, KIND, REF_ID) AS THREAD_ID, U.*
FROM (SELECT * FROM PO_T UNION ALL SELECT * FROM INV_T UNION ALL SELECT * FROM CON_T UNION ALL SELECT * FROM CMP_T) U;

CREATE OR REPLACE TABLE PROCUREMENT_EMAILS (
  EMAIL_ID            VARCHAR COMMENT 'Primary key',
  EMAIL_DATE          DATE    COMMENT 'Date sent',
  SUBJECT             VARCHAR COMMENT 'Email subject line (references supplier, PO or invoice numbers)',
  EMAIL_CATEGORY      VARCHAR COMMENT 'Procurement / Approval / Delivery / Invoice / Payment / Contract / Compliance',
  SENDER_NAME         VARCHAR COMMENT 'PeakFit buyer who sent the email',
  SENDER_EMAIL        VARCHAR COMMENT 'Buyer email address; matches BUYERS.EMAIL',
  RECIPIENT_NAME      VARCHAR COMMENT 'Supplier contact or internal PeakFit recipient',
  RECIPIENT_EMAIL     VARCHAR COMMENT 'Recipient email address',
  RELATED_SUPPLIER_ID VARCHAR COMMENT 'Supplier the email is about. Joins to SUPPLIERS.SUPPLIER_ID',
  RELATED_PO_ID       VARCHAR COMMENT 'Purchase order referenced, if any. Joins to PO_TRANSACTIONS.PO_ID',
  RELATED_INVOICE_ID  VARCHAR COMMENT 'Invoice referenced, if any. Joins to PO_INVOICES.INVOICE_ID',
  THREAD_ID           NUMBER  COMMENT 'Conversation thread identifier; emails with the same THREAD_ID belong to one conversation'
);

INSERT INTO PROCUREMENT_EMAILS
WITH E AS (
  SELECT T.*, Q.N AS K,
         1 + FLOOR({{BUILD_DB}}.GEN.U(T.KIND || T.REF_ID || ':ne') * 5.6) AS N_EMAILS
  FROM {{BUILD_DB}}.GEN.EMAIL_THREADS T
  JOIN {{BUILD_DB}}.GEN.SEQ Q ON Q.N < 6
), E2 AS (
  SELECT E.*,
         DATEADD(DAY, SUM(1 + FLOOR({{BUILD_DB}}.GEN.U(E.KIND || E.REF_ID || ':gap' || E.K) * 3))
                        OVER (PARTITION BY E.THREAD_ID ORDER BY E.K) - 1, E.ANCHOR_DATE) AS EMAIL_DATE
  FROM E WHERE E.K < E.N_EMAILS
), E3 AS (
  SELECT E2.*, B.BUYER_NAME, B.EMAIL AS BUYER_EMAIL, S.SUPPLIER_NAME,
         LOWER(REGEXP_REPLACE(SPLIT_PART(S.SUPPLIER_NAME, ' ', 1) || SPLIT_PART(S.SUPPLIER_NAME, ' ', 2), '[^A-Za-z]', '')) || '.com.au' AS SUP_DOMAIN,
         REPLACE(PC.CENTRE_NAME, 'PeakFit ', '') AS CENTRE_SHORT,
         P.PO_NUMBER, P.DESCRIPTION AS PO_DESC,
         CASE E2.KIND
           WHEN 'PO' THEN CASE E2.K
             WHEN 0 THEN 'Procurement|Quote request – {desc}'
             WHEN 1 THEN 'Procurement|PO {po} raised – {sup}'
             WHEN 2 THEN CASE WHEN E2.REF_STATUS = 'Rejected' THEN 'Approval|PO {po} rejected – please revise'
                              WHEN E2.AMOUNT > 5000 OR E2.REF_STATUS = 'Pending' THEN 'Approval|Approval required: PO {po} (${amt})'
                              ELSE 'Delivery|Delivery schedule for PO {po}' END
             WHEN 3 THEN CASE WHEN E2.REF_STATUS = 'Rejected' THEN 'Approval|PO {po} rejected – please revise'
                              WHEN E2.REF_STATUS = 'Pending' THEN 'Approval|Approval required: PO {po} (${amt})'
                              ELSE 'Approval|PO {po} approved' END
             WHEN 4 THEN 'Delivery|Goods received – PO {po}'
             ELSE 'Procurement|Variation to PO {po}' END
           WHEN 'INV' THEN CASE E2.K
             WHEN 0 THEN 'Invoice|Invoice {inv} received – PO {po}'
             WHEN 1 THEN 'Invoice|Query on invoice {inv}'
             WHEN 2 THEN DECODE(E2.REF_STATUS, 'Overdue', 'Payment|Overdue: invoice {inv} – {sup}',
                                               'On Hold', 'Payment|Invoice {inv} placed on hold',
                                               'Payment|Remittance advice – invoice {inv}')
             WHEN 3 THEN 'Payment|Payment reminder – invoice {inv}'
             WHEN 4 THEN 'Invoice|Invoice {inv} – incorrect amount'
             ELSE 'Payment|Remittance advice – invoice {inv}' END
           WHEN 'CON' THEN CASE E2.K
             WHEN 0 THEN 'Contract|Expiring agreement – {sup}'
             WHEN 2 THEN 'Contract|Contract variation – {sup}'
             ELSE 'Contract|Contract renewal – {sup}' END
           ELSE IFF(E2.K = 1, 'Compliance|Insurance certificate expiry – {sup}', 'Compliance|Compliance documents required – {sup}')
         END AS TPL
  FROM E2
  JOIN BUYERS B ON B.BUYER_ID = E2.BUYER_ID
  JOIN SUPPLIERS S ON S.SUPPLIER_ID = E2.SUPPLIER_ID
  JOIN PROFIT_CENTRES PC ON PC.PROFIT_CENTRE_ID = E2.PROFIT_CENTRE_ID
  LEFT JOIN PO_TRANSACTIONS P ON P.PO_ID = E2.PO_ID
  WHERE E2.EMAIL_DATE BETWEEN '2022-07-01'::DATE AND '2026-10-31'::DATE
), E4 AS (
  SELECT E3.*, SPLIT_PART(TPL, '|', 1) AS EMAIL_CATEGORY,
         REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(SPLIT_PART(TPL, '|', 2),
           '{desc}', COALESCE(PO_DESC, '')), '{po}', COALESCE(PO_NUMBER, '')), '{sup}', SUPPLIER_NAME),
           '{inv}', COALESCE(INVOICE_ID, '')), '{amt}', TRIM(TO_VARCHAR(ROUND(COALESCE(AMOUNT, 0)), '999,999,999'))) AS SUBJECT_RAW
  FROM E3
)
SELECT
  'EML' || LPAD(ROW_NUMBER() OVER (ORDER BY EMAIL_DATE, THREAD_ID, K), 7, '0'),
  EMAIL_DATE,
  SUBJECT_RAW,
  EMAIL_CATEGORY,
  BUYER_NAME, BUYER_EMAIL,
  CASE WHEN EMAIL_CATEGORY = 'Approval' THEN 'Centre Manager – ' || CENTRE_SHORT
       WHEN EMAIL_CATEGORY = 'Payment' AND MOD(K, 2) = 1 THEN 'PeakFit Accounts Payable'
       ELSE SUPPLIER_NAME || ' Accounts' END,
  CASE WHEN EMAIL_CATEGORY = 'Approval' THEN 'manager.' || LOWER(REGEXP_REPLACE(CENTRE_SHORT, '[^A-Za-z]', '')) || '@peakfit.com.au'
       WHEN EMAIL_CATEGORY = 'Payment' AND MOD(K, 2) = 1 THEN 'ap@peakfit.com.au'
       WHEN EMAIL_CATEGORY = 'Contract' THEN 'contracts@' || SUP_DOMAIN
       ELSE 'accounts@' || SUP_DOMAIN END,
  SUPPLIER_ID, PO_ID, INVOICE_ID, THREAD_ID
FROM E4;
