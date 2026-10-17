-- =============================================================================
-- 01_dimensions.sql — dimension tables + generation helpers (build area)
-- Runs in {{BUILD_DB}}; promoted to {{DB}}.PUBLIC later.
-- Deterministic: hand-curated values; randomness via hash-based UDFs.
-- =============================================================================

USE ROLE {{ROLE}};
USE WAREHOUSE {{WH}};
USE SCHEMA {{BUILD_DB}}.PUBLIC;

-- -----------------------------------------------------------------------------
-- Deterministic randomness: U(key) ~ Uniform(0,1), N(key) ~ Normal(0,1)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION {{BUILD_DB}}.GEN.U(K VARCHAR)
RETURNS FLOAT
AS $$ ((MOD(MOD(HASH(K), 1000000007) + 1000000007, 1000000007))::FLOAT + 0.5) / 1000000007.0 $$;

CREATE OR REPLACE FUNCTION {{BUILD_DB}}.GEN.N(K VARCHAR)
RETURNS FLOAT
AS $$ (SQRT(-2 * LN({{BUILD_DB}}.GEN.U(K || '#a'))) * COS(2 * PI() * {{BUILD_DB}}.GEN.U(K || '#b')))::FLOAT $$;

-- Integer sequence 0..999 for row expansion
CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.SEQ AS
SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS N
FROM TABLE(GENERATOR(ROWCOUNT => 1000));

-- Months Jul 2022 .. Oct 2026 (52)
CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.MONTHS AS
SELECT
  DATEADD(MONTH, N, '2022-07-01'::DATE)                          AS MONTH_START,
  LAST_DAY(DATEADD(MONTH, N, '2022-07-01'::DATE))                AS MONTH_END,
  DAY(LAST_DAY(DATEADD(MONTH, N, '2022-07-01'::DATE)))           AS DAYS_IN_MONTH,
  N                                                              AS MONTH_IDX,
  'FY' || (YEAR(DATEADD(MONTH, N, '2022-07-01'::DATE))
           + IFF(MONTH(DATEADD(MONTH, N, '2022-07-01'::DATE)) >= 7, 1, 0)) AS FINANCIAL_YEAR
FROM {{BUILD_DB}}.GEN.SEQ
WHERE N < 52;

-- =============================================================================
-- PROFIT_CENTRES
-- =============================================================================
CREATE OR REPLACE TABLE PROFIT_CENTRES (
  PROFIT_CENTRE_ID VARCHAR COMMENT 'Primary key. Referenced by PROFIT_CENTRE_ID in PO_TRANSACTIONS, BUDGETS, STAFF_ROSTER, STAFF_COSTS, SUPPLIER_ASSESSMENTS, ASSET_REGISTER, INCIDENT_LOG and by BUYERS.HOME_CENTRE_ID',
  CENTRE_NAME      VARCHAR COMMENT 'PeakFit centre name, e.g. PeakFit Bondi',
  STATE            VARCHAR COMMENT 'Australian state: NSW, VIC, QLD, SA, WA, ACT. Suppliers service a centre when this state is in SUPPLIERS.SERVICE_REGIONS',
  CENTRE_SIZE      VARCHAR COMMENT 'large / medium / small',
  HAS_POOL         BOOLEAN COMMENT 'TRUE if the centre has a pool. Only pool centres have Pool Lifeguard staff, pool assets and Pool & Aquatic Services suppliers'
) COMMENT = 'One row per PeakFit fitness centre (23 centres across 6 states). Also called cost centre. Hub dimension shared by procurement, finance, workforce and ancillary tables.';

INSERT INTO PROFIT_CENTRES VALUES
  ('PC001','PeakFit Bondi','NSW','large',TRUE),
  ('PC002','PeakFit Parramatta','NSW','large',TRUE),
  ('PC003','PeakFit Chatswood','NSW','medium',TRUE),
  ('PC004','PeakFit Newcastle','NSW','medium',TRUE),
  ('PC005','PeakFit Penrith','NSW','small',FALSE),
  ('PC006','PeakFit Wollongong','NSW','small',FALSE),
  ('PC007','PeakFit Southbank','VIC','large',TRUE),
  ('PC008','PeakFit Richmond','VIC','large',TRUE),
  ('PC009','PeakFit St Kilda','VIC','medium',TRUE),
  ('PC010','PeakFit Geelong','VIC','medium',TRUE),
  ('PC011','PeakFit Box Hill','VIC','small',FALSE),
  ('PC012','PeakFit Ballarat','VIC','small',FALSE),
  ('PC013','PeakFit Fortitude Valley','QLD','large',TRUE),
  ('PC014','PeakFit Surfers Paradise','QLD','medium',TRUE),
  ('PC015','PeakFit Chermside','QLD','medium',FALSE),
  ('PC016','PeakFit Townsville','QLD','small',FALSE),
  ('PC017','PeakFit Toowoomba','QLD','small',FALSE),
  ('PC018','PeakFit Perth CBD','WA','large',TRUE),
  ('PC019','PeakFit Fremantle','WA','medium',TRUE),
  ('PC020','PeakFit Joondalup','WA','small',FALSE),
  ('PC021','PeakFit Adelaide CBD','SA','large',TRUE),
  ('PC022','PeakFit Glenelg','SA','medium',TRUE),
  ('PC023','PeakFit Canberra Civic','ACT','medium',TRUE);

-- =============================================================================
-- SUPPLIERS
-- =============================================================================
CREATE OR REPLACE TABLE SUPPLIERS (
  SUPPLIER_ID       VARCHAR COMMENT 'Primary key. Referenced by SUPPLIER_ID in PO_TRANSACTIONS, PO_INVOICES, CONTRACTS, SUPPLIER_ASSESSMENTS, by ASSET_REGISTER.WARRANTY_SUPPLIER_ID and PROCUREMENT_EMAILS.RELATED_SUPPLIER_ID',
  SUPPLIER_NAME     VARCHAR COMMENT 'Registered supplier (vendor) name',
  CATEGORY          VARCHAR COMMENT 'Supplier category (14 values). Category spend is grouped by this column, not by spend code',
  COMPLIANCE_STATUS VARCHAR COMMENT 'Compliant / Under Review / Non-Compliant (insurance, ABN and safety documentation)',
  ABN               VARCHAR COMMENT 'Australian Business Number',
  SERVICE_REGIONS   ARRAY   COMMENT 'States the supplier services. Join to PROFIT_CENTRES with ARRAY_CONTAINS(STATE::VARIANT, SERVICE_REGIONS)'
) COMMENT = 'Supplier (vendor) master: 50 suppliers in 14 categories. Hub dimension for procurement and supplier management.';

INSERT INTO SUPPLIERS (SUPPLIER_ID, SUPPLIER_NAME, CATEGORY, COMPLIANCE_STATUS, ABN, SERVICE_REGIONS)
SELECT
  ID, NAME, CAT, COMP,
  LPAD(MOD(ABS(HASH(ID, 'abn')), 100), 2, '0') || ' ' ||
  LPAD(MOD(ABS(HASH(ID, 'abn2')), 1000), 3, '0') || ' ' ||
  LPAD(MOD(ABS(HASH(ID, 'abn3')), 1000), 3, '0') || ' ' ||
  LPAD(MOD(ABS(HASH(ID, 'abn4')), 1000), 3, '0'),
  SPLIT(REGIONS, ',')
FROM VALUES
  ('SUP001','SparkleClean Commercial Pty Ltd','Cleaning Services','Compliant','NSW,VIC,QLD,SA,WA,ACT'),
  ('SUP002','Harbour City Cleaning Co','Cleaning Services','Compliant','NSW,ACT'),
  ('SUP003','Southern Cross Hygiene Services','Cleaning Services','Compliant','VIC,SA'),
  ('SUP004','Sunstate Cleaning Group','Cleaning Services','Under Review','QLD'),
  ('SUP005','Apex Facility Services','Facilities Maintenance','Compliant','NSW,VIC,QLD,SA,WA,ACT'),
  ('SUP006','Metro Building Maintenance','Facilities Maintenance','Compliant','NSW,VIC'),
  ('SUP007','Coastline Property Services','Facilities Maintenance','Compliant','QLD,NSW'),
  ('SUP008','Westside Maintenance Solutions','Facilities Maintenance','Non-Compliant','WA,SA'),
  ('SUP009','IronForge Fitness Supply','Fitness Equipment','Compliant','NSW,VIC,QLD,SA,WA,ACT'),
  ('SUP010','Pulse Gym Equipment Australia','Fitness Equipment','Compliant','NSW,VIC,QLD,SA,WA,ACT'),
  ('SUP011','Kinetic Commercial Fitness','Fitness Equipment','Compliant','VIC,NSW,QLD'),
  ('SUP012','Titan Strength Systems','Fitness Equipment','Compliant','NSW,VIC,QLD,WA'),
  ('SUP013','FitTech Service & Repair','Equipment Servicing','Compliant','NSW,VIC,QLD,SA,WA,ACT'),
  ('SUP014','GymCare Technical Services','Equipment Servicing','Compliant','NSW,VIC,ACT'),
  ('SUP015','Precision Equipment Servicing','Equipment Servicing','Under Review','QLD,WA,SA'),
  ('SUP016','Nexus IT Solutions','IT Services','Compliant','NSW,VIC,QLD,SA,WA,ACT'),
  ('SUP017','CloudBridge Managed Services','IT Services','Compliant','NSW,VIC,QLD,SA,WA,ACT'),
  ('SUP018','Bluegum Technology Partners','IT Services','Compliant','NSW,VIC'),
  ('SUP019','Outback Networks','IT Services','Non-Compliant','WA,SA,QLD'),
  ('SUP020','MemberHub Software','Software & SaaS','Compliant','NSW,VIC,QLD,SA,WA,ACT'),
  ('SUP021','Rostera Workforce Cloud','Software & SaaS','Compliant','NSW,VIC,QLD,SA,WA,ACT'),
  ('SUP022','BookFit Scheduling','Software & SaaS','Compliant','NSW,VIC,QLD,SA,WA,ACT'),
  ('SUP023','LedgerLine Finance Systems','Software & SaaS','Compliant','NSW,VIC,QLD,SA,WA,ACT'),
  ('SUP024','Brightside Creative Agency','Marketing & Advertising','Compliant','NSW,VIC,QLD,SA,WA,ACT'),
  ('SUP025','Momentum Digital Marketing','Marketing & Advertising','Compliant','NSW,VIC,QLD'),
  ('SUP026','Local Pulse Media','Marketing & Advertising','Under Review','QLD,NSW'),
  ('SUP027','Signal Print & Signage','Marketing & Advertising','Compliant','NSW,VIC,QLD,SA,WA,ACT'),
  ('SUP028','Sentinel Security Group','Security Services','Compliant','NSW,VIC,QLD,SA,WA,ACT'),
  ('SUP029','Guardian Patrol Services','Security Services','Compliant','NSW,ACT,VIC'),
  ('SUP030','Vigilant Alarm Monitoring','Security Services','Non-Compliant','QLD,WA,SA'),
  ('SUP031','PowerGrid Energy Retail','Utilities & Energy','Compliant','NSW,VIC,QLD,SA,WA,ACT'),
  ('SUP032','AquaFlow Water Services','Utilities & Energy','Compliant','NSW,VIC,QLD'),
  ('SUP033','GreenVolt Solar & Energy','Utilities & Energy','Compliant','WA,SA,QLD'),
  ('SUP034','BlueWave Pool Services','Pool & Aquatic Services','Compliant','NSW,VIC,QLD,SA,WA,ACT'),
  ('SUP035','ClearWater Aquatic Maintenance','Pool & Aquatic Services','Compliant','NSW,VIC,ACT'),
  ('SUP036','AquaSafe Chemical Supplies','Pool & Aquatic Services','Under Review','QLD,WA,SA,NSW'),
  ('SUP037','Lifeline Pool Plant Services','Pool & Aquatic Services','Compliant','NSW,VIC,QLD,SA,WA,ACT'),
  ('SUP038','Climate Control Australia','HVAC Services','Compliant','NSW,VIC,QLD,SA,WA,ACT'),
  ('SUP039','AirFlow Mechanical Services','HVAC Services','Compliant','NSW,VIC,ACT'),
  ('SUP040','CoolBreeze HVAC Solutions','HVAC Services','Under Review','QLD,WA,SA'),
  ('SUP041','Meridian Advisory Partners','Professional Services','Compliant','NSW,VIC,QLD,SA,WA,ACT'),
  ('SUP042','Clarke & Hughes Legal','Professional Services','Compliant','NSW,VIC'),
  ('SUP043','Ironbark Recruitment','Professional Services','Compliant','NSW,VIC,QLD,SA,WA,ACT'),
  ('SUP044','Summit Compliance Consulting','Professional Services','Compliant','NSW,VIC,QLD,SA,WA,ACT'),
  ('SUP045','OfficeHub Supplies','Office Supplies','Compliant','NSW,VIC,QLD,SA,WA,ACT'),
  ('SUP046','Paperclip Business Supplies','Office Supplies','Compliant','NSW,VIC,QLD'),
  ('SUP047','Workspace Essentials WA','Office Supplies','Non-Compliant','WA,SA'),
  ('SUP048','FuelUp Nutrition Supplies','Catering & Nutrition','Compliant','NSW,VIC,QLD,SA,WA,ACT'),
  ('SUP049','GreenLeaf Cafe Supplies','Catering & Nutrition','Compliant','NSW,VIC,ACT'),
  ('SUP050','ProteinWorks Wholesale','Catering & Nutrition','Under Review','QLD,WA,SA,NSW')
  AS V(ID, NAME, CAT, COMP, REGIONS);

-- =============================================================================
-- BUYERS
-- =============================================================================
CREATE OR REPLACE TABLE BUYERS (
  BUYER_ID       VARCHAR COMMENT 'Primary key. Referenced by PO_TRANSACTIONS.BUYER_ID',
  BUYER_NAME     VARCHAR COMMENT 'Buyer full name',
  EMAIL          VARCHAR COMMENT 'Work email. PROCUREMENT_EMAILS.SENDER_EMAIL matches this column (no buyer ID on emails)',
  ROLE_TITLE     VARCHAR COMMENT 'Senior Buyer / Procurement Officer / Centre Procurement Coordinator',
  HOME_CENTRE_ID VARCHAR COMMENT 'The buyer''s home centre. Joins to PROFIT_CENTRES.PROFIT_CENTRE_ID'
) COMMENT = 'PeakFit staff who raise purchase orders (30 buyers; large centres have 2, others 1).';

INSERT INTO BUYERS (BUYER_ID, BUYER_NAME, EMAIL, ROLE_TITLE, HOME_CENTRE_ID)
SELECT ID, NAME, EMAIL, TITLE, CENTRE
FROM VALUES
  ('BUY001','Sarah Mitchell','sarah.mitchell@peakfit.com.au','Senior Buyer','PC001'),
  ('BUY002','James Nguyen','james.nguyen@peakfit.com.au','Procurement Officer','PC001'),
  ('BUY003','Priya Sharma','priya.sharma@peakfit.com.au','Senior Buyer','PC002'),
  ('BUY004','Daniel O''Connor','daniel.oconnor@peakfit.com.au','Procurement Officer','PC002'),
  ('BUY005','Emily Chen','emily.chen@peakfit.com.au','Procurement Officer','PC003'),
  ('BUY006','Liam Walsh','liam.walsh@peakfit.com.au','Procurement Officer','PC004'),
  ('BUY007','Hannah Kelly','hannah.kelly@peakfit.com.au','Centre Procurement Coordinator','PC005'),
  ('BUY008','Marcus Rossi','marcus.rossi@peakfit.com.au','Centre Procurement Coordinator','PC006'),
  ('BUY009','Olivia Brown','olivia.brown@peakfit.com.au','Senior Buyer','PC007'),
  ('BUY010','Ethan Papadopoulos','ethan.papadopoulos@peakfit.com.au','Procurement Officer','PC007'),
  ('BUY011','Chloe Wilson','chloe.wilson@peakfit.com.au','Senior Buyer','PC008'),
  ('BUY012','Ryan Tran','ryan.tran@peakfit.com.au','Procurement Officer','PC008'),
  ('BUY013','Grace Taylor','grace.taylor@peakfit.com.au','Procurement Officer','PC009'),
  ('BUY014','Noah Patel','noah.patel@peakfit.com.au','Procurement Officer','PC010'),
  ('BUY015','Isabella Martin','isabella.martin@peakfit.com.au','Centre Procurement Coordinator','PC011'),
  ('BUY016','Jack Thompson','jack.thompson@peakfit.com.au','Centre Procurement Coordinator','PC012'),
  ('BUY017','Mia Robinson','mia.robinson@peakfit.com.au','Senior Buyer','PC013'),
  ('BUY018','Lucas Fraser','lucas.fraser@peakfit.com.au','Procurement Officer','PC013'),
  ('BUY019','Zoe Anderson','zoe.anderson@peakfit.com.au','Procurement Officer','PC014'),
  ('BUY020','Oliver Singh','oliver.singh@peakfit.com.au','Procurement Officer','PC015'),
  ('BUY021','Ava Campbell','ava.campbell@peakfit.com.au','Centre Procurement Coordinator','PC016'),
  ('BUY022','William Lee','william.lee@peakfit.com.au','Centre Procurement Coordinator','PC017'),
  ('BUY023','Sophie Clarke','sophie.clarke@peakfit.com.au','Senior Buyer','PC018'),
  ('BUY024','Benjamin Hughes','benjamin.hughes@peakfit.com.au','Procurement Officer','PC018'),
  ('BUY025','Ella Murphy','ella.murphy@peakfit.com.au','Procurement Officer','PC019'),
  ('BUY026','Thomas Nguyen','thomas.nguyen@peakfit.com.au','Centre Procurement Coordinator','PC020'),
  ('BUY027','Charlotte King','charlotte.king@peakfit.com.au','Senior Buyer','PC021'),
  ('BUY028','Henry Wright','henry.wright@peakfit.com.au','Procurement Officer','PC021'),
  ('BUY029','Amelia Scott','amelia.scott@peakfit.com.au','Procurement Officer','PC022'),
  ('BUY030','Samuel Baker','samuel.baker@peakfit.com.au','Procurement Officer','PC023')
  AS V(ID, NAME, EMAIL, TITLE, CENTRE);

-- =============================================================================
-- GL_HIERARCHY (20 accounts; every account can carry postings and a budget;
-- roll-ups = own postings + descendants via PARENT_GL_ID)
-- =============================================================================
CREATE OR REPLACE TABLE GL_HIERARCHY (
  GL_ACCOUNT_ID   VARCHAR COMMENT 'Primary key. Referenced by PO_TRANSACTIONS.GL_ACCOUNT_ID and BUDGETS.GL_ACCOUNT_ID',
  GL_ACCOUNT_NAME VARCHAR COMMENT 'General ledger account name',
  GL_CATEGORY     VARCHAR COMMENT 'Operations / Technology / Marketing / Admin / Capital',
  PARENT_GL_ID    VARCHAR COMMENT 'Parent account (self-reference to GL_HIERARCHY.GL_ACCOUNT_ID). NULL for top-level accounts'
) COMMENT = 'Chart of accounts used for POs and budgets: 20 accounts in a two-level hierarchy.';

INSERT INTO GL_HIERARCHY VALUES
  ('GL6100','Facility Operations','Operations',NULL),
  ('GL6110','Cleaning & Hygiene','Operations','GL6100'),
  ('GL6120','Repairs & Maintenance','Operations','GL6100'),
  ('GL6130','Utilities','Operations','GL6100'),
  ('GL6140','Pool Operations','Operations','GL6100'),
  ('GL6150','Security','Operations','GL6100'),
  ('GL6160','Equipment Servicing & Minor Equipment','Operations','GL6100'),
  ('GL6170','Member Amenities & Nutrition','Operations','GL6100'),
  ('GL7100','Technology Services','Technology',NULL),
  ('GL7110','IT Support & Managed Services','Technology','GL7100'),
  ('GL7120','Software Subscriptions','Technology','GL7100'),
  ('GL7500','Marketing','Marketing',NULL),
  ('GL7510','Digital Advertising','Marketing','GL7500'),
  ('GL7520','Print & Signage','Marketing','GL7500'),
  ('GL8100','Administration','Admin',NULL),
  ('GL8110','Professional Fees','Admin','GL8100'),
  ('GL8120','Office Supplies','Admin','GL8100'),
  ('GL9100','Capital Works','Capital',NULL),
  ('GL9110','Fitness Equipment Capex','Capital','GL9100'),
  ('GL9120','Building Fitout & HVAC Capex','Capital','GL9100');

-- =============================================================================
-- SPEND_CODES (126 codes rolling up to 20 names — natural duplication)
-- =============================================================================
CREATE OR REPLACE TABLE SPEND_CODES (
  SPEND_CODE_ID   VARCHAR COMMENT 'Primary key. Referenced by PO_TRANSACTIONS.SPEND_CODE_ID',
  SPEND_CODE_NAME VARCHAR COMMENT 'Spend code name (20 distinct names; several codes share a name). Not the same taxonomy as SUPPLIERS.CATEGORY'
) COMMENT = 'Procurement spend codes: 126 codes that roll up to 20 spend code names.';

INSERT INTO SPEND_CODES (SPEND_CODE_ID, SPEND_CODE_NAME)
WITH NAMES AS (
  SELECT NAME, ORD, N_CODES
  FROM VALUES
    ('Cleaning Services',1,7), ('Waste Management',2,6), ('Building Maintenance',3,7),
    ('Plumbing & Electrical',4,6), ('Utilities',5,6), ('Pool Chemicals',6,6),
    ('Pool Maintenance',7,6), ('Security Services',8,6), ('Fitness Equipment Purchase',9,7),
    ('Equipment Repairs',10,7), ('IT Services',11,7), ('Software Licences',12,6),
    ('Digital Marketing',13,6), ('Print & Signage',14,6), ('Legal Services',15,6),
    ('Consulting',16,6), ('Recruitment',17,6), ('Office Supplies',18,6),
    ('Catering Supplies',19,6), ('HVAC Services',20,7)
    AS V(NAME, ORD, N_CODES)
)
SELECT
  'SC' || LPAD(ROW_NUMBER() OVER (ORDER BY NM.ORD, S.N), 3, '0'),
  NM.NAME
FROM NAMES NM
JOIN {{BUILD_DB}}.GEN.SEQ S ON S.N < NM.N_CODES;

-- =============================================================================
-- Generation helpers (GEN schema — not promoted)
-- =============================================================================

-- Category profile: frequency, PO amount distribution, GL mapping
CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.CATEGORY_PROFILE AS
SELECT * FROM VALUES
  -- category, freq, amt_median, amt_sigma, gl_opex, gl_capex, capex_threshold, is_goods, capital_rate
  ('Cleaning Services',        14, 1400, 0.60, 'GL6110', NULL,     NULL,  FALSE, 0.000),
  ('Facilities Maintenance',   12, 2200, 0.90, 'GL6120', 'GL9120', 40000, FALSE, 0.004),
  ('Fitness Equipment',         5, 6500, 1.10, 'GL6160', 'GL9110', 10000, TRUE,  0.010),
  ('Equipment Servicing',      10, 1300, 0.70, 'GL6160', NULL,     NULL,  FALSE, 0.000),
  ('IT Services',               7, 2800, 0.90, 'GL7110', NULL,     NULL,  FALSE, 0.000),
  ('Software & SaaS',           5, 1800, 1.00, 'GL7120', NULL,     NULL,  FALSE, 0.000),
  ('Marketing & Advertising',   7, 3200, 0.90, 'GL7510', NULL,     NULL,  FALSE, 0.000),
  ('Security Services',         6, 1600, 0.60, 'GL6150', NULL,     NULL,  FALSE, 0.000),
  ('Utilities & Energy',        8, 3000, 0.60, 'GL6130', NULL,     NULL,  FALSE, 0.000),
  ('Pool & Aquatic Services',   7, 1600, 0.70, 'GL6140', NULL,     NULL,  FALSE, 0.000),
  ('HVAC Services',             6, 2400, 1.00, 'GL6120', 'GL9120', 25000, FALSE, 0.006),
  ('Professional Services',     4, 4200, 1.00, 'GL8110', NULL,     NULL,  FALSE, 0.000),
  ('Office Supplies',           5,  380, 0.70, 'GL8120', NULL,     NULL,  TRUE,  0.000),
  ('Catering & Nutrition',      3,  520, 0.70, 'GL6170', NULL,     NULL,  TRUE,  0.000)
  AS V(CATEGORY, FREQ, AMT_MEDIAN, AMT_SIGMA, GL_OPEX, GL_CAPEX, CAPEX_THRESHOLD, IS_GOODS, CAPITAL_RATE);

-- Supplier profile: selection share within category, spend code names, payment terms, base quality
CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.SUPPLIER_PROFILE AS
SELECT
  V.SUPPLIER_ID, V.SHARE, V.SPEND_PRIMARY, V.SPEND_SECONDARY, V.SECONDARY_SHARE,
  CASE WHEN {{BUILD_DB}}.GEN.U(V.SUPPLIER_ID || ':terms') < 0.2 THEN 14
       WHEN {{BUILD_DB}}.GEN.U(V.SUPPLIER_ID || ':terms') < 0.8 THEN 30
       ELSE 45 END                                                        AS PAYMENT_TERMS_DAYS,
  ROUND(3.40 + 1.05 * {{BUILD_DB}}.GEN.U(V.SUPPLIER_ID || ':quality'), 2) AS BASE_QUALITY
FROM VALUES
  ('SUP001',0.50,'Cleaning Services','Waste Management',0.15),
  ('SUP002',0.25,'Cleaning Services','Waste Management',0.15),
  ('SUP003',0.15,'Cleaning Services','Waste Management',0.15),
  ('SUP004',0.10,'Cleaning Services','Waste Management',0.15),
  ('SUP005',0.45,'Building Maintenance','Plumbing & Electrical',0.40),
  ('SUP006',0.25,'Building Maintenance','Plumbing & Electrical',0.40),
  ('SUP007',0.15,'Building Maintenance','Plumbing & Electrical',0.40),
  ('SUP008',0.15,'Building Maintenance','Plumbing & Electrical',0.40),
  ('SUP009',0.40,'Fitness Equipment Purchase',NULL,0),
  ('SUP010',0.30,'Fitness Equipment Purchase',NULL,0),
  ('SUP011',0.15,'Fitness Equipment Purchase',NULL,0),
  ('SUP012',0.15,'Fitness Equipment Purchase',NULL,0),
  ('SUP013',0.50,'Equipment Repairs',NULL,0),
  ('SUP014',0.30,'Equipment Repairs',NULL,0),
  ('SUP015',0.20,'Equipment Repairs',NULL,0),
  ('SUP016',0.45,'IT Services',NULL,0),
  ('SUP017',0.30,'IT Services',NULL,0),
  ('SUP018',0.15,'IT Services',NULL,0),
  ('SUP019',0.10,'IT Services',NULL,0),
  ('SUP020',0.40,'Software Licences',NULL,0),
  ('SUP021',0.25,'Software Licences',NULL,0),
  ('SUP022',0.20,'Software Licences',NULL,0),
  ('SUP023',0.15,'Software Licences',NULL,0),
  ('SUP024',0.40,'Digital Marketing',NULL,0),
  ('SUP025',0.30,'Digital Marketing',NULL,0),
  ('SUP026',0.10,'Digital Marketing',NULL,0),
  ('SUP027',0.20,'Print & Signage',NULL,0),
  ('SUP028',0.55,'Security Services',NULL,0),
  ('SUP029',0.25,'Security Services',NULL,0),
  ('SUP030',0.20,'Security Services',NULL,0),
  ('SUP031',0.60,'Utilities',NULL,0),
  ('SUP032',0.25,'Utilities',NULL,0),
  ('SUP033',0.15,'Utilities',NULL,0),
  ('SUP034',0.45,'Pool Maintenance','Pool Chemicals',0.30),
  ('SUP035',0.25,'Pool Maintenance','Pool Chemicals',0.20),
  ('SUP036',0.15,'Pool Chemicals',NULL,0),
  ('SUP037',0.15,'Pool Maintenance',NULL,0),
  ('SUP038',0.50,'HVAC Services',NULL,0),
  ('SUP039',0.30,'HVAC Services',NULL,0),
  ('SUP040',0.20,'HVAC Services',NULL,0),
  ('SUP041',0.35,'Consulting',NULL,0),
  ('SUP042',0.20,'Legal Services',NULL,0),
  ('SUP043',0.25,'Recruitment',NULL,0),
  ('SUP044',0.20,'Consulting',NULL,0),
  ('SUP045',0.55,'Office Supplies',NULL,0),
  ('SUP046',0.30,'Office Supplies',NULL,0),
  ('SUP047',0.15,'Office Supplies',NULL,0),
  ('SUP048',0.50,'Catering Supplies',NULL,0),
  ('SUP049',0.30,'Catering Supplies',NULL,0),
  ('SUP050',0.20,'Catering Supplies',NULL,0)
  AS V(SUPPLIER_ID, SHARE, SPEND_PRIMARY, SPEND_SECONDARY, SECONDARY_SHARE);

-- Eligible suppliers per centre (state coverage; pool suppliers only at pool centres),
-- with cumulative selection weights for weighted picks
CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.CENTRE_SUPPLIER AS
WITH E AS (
  SELECT P.PROFIT_CENTRE_ID, S.SUPPLIER_ID, S.CATEGORY, C.FREQ * SP.SHARE AS W
  FROM PROFIT_CENTRES P
  JOIN SUPPLIERS S ON ARRAY_CONTAINS(P.STATE::VARIANT, S.SERVICE_REGIONS)
  JOIN {{BUILD_DB}}.GEN.SUPPLIER_PROFILE SP ON SP.SUPPLIER_ID = S.SUPPLIER_ID
  JOIN {{BUILD_DB}}.GEN.CATEGORY_PROFILE C ON C.CATEGORY = S.CATEGORY
  WHERE S.CATEGORY <> 'Pool & Aquatic Services' OR P.HAS_POOL
)
SELECT
  PROFIT_CENTRE_ID, SUPPLIER_ID, CATEGORY, W,
  COALESCE(SUM(W) OVER (PARTITION BY PROFIT_CENTRE_ID ORDER BY SUPPLIER_ID
                        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)
    / SUM(W) OVER (PARTITION BY PROFIT_CENTRE_ID) AS CUM_LO,
  SUM(W) OVER (PARTITION BY PROFIT_CENTRE_ID ORDER BY SUPPLIER_ID
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
    / SUM(W) OVER (PARTITION BY PROFIT_CENTRE_ID) AS CUM_HI
FROM E;

-- Buyer candidates per centre: home buyers 90%, same-state cover 10%
CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.CENTRE_BUYER AS
WITH C AS (
  SELECT P.PROFIT_CENTRE_ID, B.BUYER_ID,
         CASE WHEN B.HOME_CENTRE_ID = P.PROFIT_CENTRE_ID THEN 'HOME' ELSE 'COVER' END AS KIND
  FROM PROFIT_CENTRES P
  JOIN BUYERS B ON B.HOME_CENTRE_ID IN (SELECT PROFIT_CENTRE_ID FROM PROFIT_CENTRES WHERE STATE = P.STATE)
), W AS (
  SELECT C.*,
         IFF(KIND = 'HOME',
             IFF(COUNT_IF(KIND = 'COVER') OVER (PARTITION BY PROFIT_CENTRE_ID) = 0, 1.0, 0.9)
               / COUNT_IF(KIND = 'HOME') OVER (PARTITION BY PROFIT_CENTRE_ID),
             0.1 / NULLIF(COUNT_IF(KIND = 'COVER') OVER (PARTITION BY PROFIT_CENTRE_ID), 0)) AS W
  FROM C
)
SELECT PROFIT_CENTRE_ID, BUYER_ID, KIND, W,
  COALESCE(SUM(W) OVER (PARTITION BY PROFIT_CENTRE_ID ORDER BY BUYER_ID
                        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS CUM_LO,
  SUM(W) OVER (PARTITION BY PROFIT_CENTRE_ID ORDER BY BUYER_ID
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS CUM_HI
FROM W;

-- Spend code lookup: name -> (index, code)
CREATE OR REPLACE TABLE {{BUILD_DB}}.GEN.SPEND_NAME_CODES AS
SELECT SPEND_CODE_NAME, SPEND_CODE_ID,
       ROW_NUMBER() OVER (PARTITION BY SPEND_CODE_NAME ORDER BY SPEND_CODE_ID) - 1 AS IDX,
       COUNT(*) OVER (PARTITION BY SPEND_CODE_NAME) AS N_CODES
FROM SPEND_CODES;
