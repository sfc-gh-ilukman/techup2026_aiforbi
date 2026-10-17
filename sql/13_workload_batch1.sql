-- =============================================================================
-- 13_workload_batch1.sql — realistic analyst query history for Cortex Sense
--
-- 27 templates across 6 personas. Run as your own user against {{DB}}
-- (never the build DB) so they land in ACCOUNT_USAGE.QUERY_HISTORY.
-- Rules:
--   * Building blocks only — no single query answers Q2 end to end.
--   * Each persona block sets a JSON QUERY_TAG.
--   * Batch 1 = every template once (plus hot templates repeated with other params).
--     Batches 2 and 3 re-run the hot templates with different parameters on later days.
-- =============================================================================

USE ROLE {{ROLE}};
USE WAREHOUSE {{WH}};
USE DATABASE {{DB}};

-- -----------------------------------------------------------------------------
-- Persona: procurement_analyst
-- -----------------------------------------------------------------------------
ALTER SESSION SET QUERY_TAG = '{"team":"procurement","persona":"procurement_analyst","tool":"worksheet"}';

-- T01 Approved spend by state for a financial year
SELECT pc.state, ROUND(SUM(po.amount), 2) AS approved_spend, COUNT(*) AS po_count
FROM PUBLIC.PO_TRANSACTIONS po
JOIN PUBLIC.PROFIT_CENTRES pc ON pc.profit_centre_id = po.profit_centre_id
WHERE po.status = 'Approved' AND po.financial_year = 'FY2026'
GROUP BY pc.state
ORDER BY approved_spend DESC;

-- T02 Category spend (supplier category, not spend code)
SELECT s.category, ROUND(SUM(po.amount), 2) AS approved_spend
FROM PUBLIC.PO_TRANSACTIONS po
JOIN PUBLIC.SUPPLIERS s ON s.supplier_id = po.supplier_id
WHERE po.status = 'Approved' AND po.financial_year = 'FY2026'
GROUP BY s.category
ORDER BY approved_spend DESC;

-- T03 Approved spend by supplier for a financial year
SELECT s.supplier_id, s.supplier_name, s.category, ROUND(SUM(po.amount), 2) AS approved_spend
FROM PUBLIC.PO_TRANSACTIONS po
JOIN PUBLIC.SUPPLIERS s ON s.supplier_id = po.supplier_id
WHERE po.status = 'Approved' AND po.financial_year = 'FY2026'
GROUP BY 1, 2, 3
ORDER BY approved_spend DESC;

-- T04 Tail spend: suppliers after the 80% cumulative spend point
WITH s AS (
  SELECT supplier_id, SUM(amount) AS spend
  FROM PUBLIC.PO_TRANSACTIONS
  WHERE status = 'Approved' AND financial_year = 'FY2026'
  GROUP BY 1
), c AS (
  SELECT supplier_id, spend,
         SUM(spend) OVER (ORDER BY spend DESC, supplier_id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS spend_before,
         SUM(spend) OVER () AS total
  FROM s
)
SELECT COUNT_IF(COALESCE(spend_before, 0) >= 0.8 * total) AS tail_suppliers,
       ROUND(SUM(IFF(COALESCE(spend_before, 0) >= 0.8 * total, spend, 0)), 2) AS tail_spend,
       ROUND(MAX(total), 2) AS total_spend
FROM c;

-- T05 Maverick (off-contract) spend: approved POs with no contract covering the PO date
SELECT s.supplier_name, ROUND(SUM(po.amount), 2) AS off_contract_spend, COUNT(*) AS po_count
FROM PUBLIC.PO_TRANSACTIONS po
JOIN PUBLIC.SUPPLIERS s ON s.supplier_id = po.supplier_id
WHERE po.status = 'Approved' AND po.financial_year = 'FY2026'
  AND NOT EXISTS (SELECT 1 FROM PUBLIC.CONTRACTS c
                  WHERE c.supplier_id = po.supplier_id AND po.po_date BETWEEN c.start_date AND c.end_date)
GROUP BY 1
ORDER BY off_contract_spend DESC;

-- T06 Split-PO review (Approval Policy s3): same buyer + supplier + spend code, within 3 days, each $4k-$5k, combined > $5k
SELECT b.buyer_name, COUNT(DISTINCT a.po_id) AS flagged_pos
FROM PUBLIC.PO_TRANSACTIONS a
JOIN PUBLIC.PO_TRANSACTIONS x
  ON x.buyer_id = a.buyer_id AND x.supplier_id = a.supplier_id AND x.spend_code_id = a.spend_code_id
 AND x.po_id <> a.po_id AND ABS(DATEDIFF(day, a.po_date, x.po_date)) <= 3
JOIN PUBLIC.BUYERS b ON b.buyer_id = a.buyer_id
WHERE a.status = 'Approved' AND x.status = 'Approved'
  AND a.amount BETWEEN 4000 AND 5000 AND x.amount BETWEEN 4000 AND 5000
  AND a.amount + x.amount > 5000
  AND a.financial_year = 'FY2026'
GROUP BY 1
ORDER BY flagged_pos DESC;

-- T07 Overdue invoices by supplier
SELECT s.supplier_name, COUNT(*) AS overdue_invoices, ROUND(SUM(i.invoice_amount), 2) AS overdue_amount
FROM PUBLIC.PO_INVOICES i
JOIN PUBLIC.SUPPLIERS s ON s.supplier_id = i.supplier_id
WHERE i.payment_status = 'Overdue'
GROUP BY 1
ORDER BY overdue_amount DESC;

-- T08 Approval level mix by buyer
SELECT b.buyer_name, po.approval_level, COUNT(*) AS pos, ROUND(SUM(po.amount), 2) AS value
FROM PUBLIC.PO_TRANSACTIONS po
JOIN PUBLIC.BUYERS b ON b.buyer_id = po.buyer_id
WHERE po.financial_year = 'FY2026'
GROUP BY 1, 2
ORDER BY 1, 2;

-- -----------------------------------------------------------------------------
-- Persona: supplier_manager
-- -----------------------------------------------------------------------------
ALTER SESSION SET QUERY_TAG = '{"team":"procurement","persona":"supplier_manager","tool":"worksheet"}';

-- T09 Supplier performance score by period (average across centres), periods ordered FY then half
SELECT supplier_id, assessment_period,
       ROUND(AVG(overall_score), 2) AS supplier_score, COUNT(*) AS centres_assessed
FROM PUBLIC.SUPPLIER_ASSESSMENTS
GROUP BY 1, 2
ORDER BY supplier_id,
         TO_NUMBER(SUBSTR(assessment_period, 6, 4)), TO_NUMBER(SUBSTR(assessment_period, 2, 1));

-- T10 Sustained poor performance: supplier score < 3.00 in each of the two latest completed periods
WITH p AS (
  SELECT DISTINCT assessment_period,
         TO_NUMBER(SUBSTR(assessment_period, 6, 4)) * 10 + TO_NUMBER(SUBSTR(assessment_period, 2, 1)) AS ord
  FROM PUBLIC.SUPPLIER_ASSESSMENTS
), last2 AS (
  SELECT assessment_period FROM p QUALIFY ROW_NUMBER() OVER (ORDER BY ord DESC) <= 2
), s AS (
  SELECT a.supplier_id, a.assessment_period, AVG(a.overall_score) AS supplier_score
  FROM PUBLIC.SUPPLIER_ASSESSMENTS a JOIN last2 USING (assessment_period)
  GROUP BY 1, 2
)
SELECT supplier_id, ROUND(MIN(supplier_score), 2) AS min_score, ROUND(MAX(supplier_score), 2) AS max_score
FROM s
GROUP BY 1
HAVING COUNT(*) = 2 AND MAX(supplier_score) < 3.00
ORDER BY 1;

-- T11 Serious incidents attributed to suppliers (via the related PO), last 6 months
SELECT po.supplier_id, s.supplier_name, COUNT(*) AS high_critical_incidents
FROM PUBLIC.INCIDENT_LOG i
JOIN PUBLIC.PO_TRANSACTIONS po ON po.po_id = i.related_po_id
JOIN PUBLIC.SUPPLIERS s ON s.supplier_id = po.supplier_id
WHERE i.severity IN ('High', 'Critical')
  AND i.incident_date BETWEEN '2026-05-01' AND '2026-10-31'
GROUP BY 1, 2
ORDER BY high_critical_incidents DESC;

-- T12 Incidents by centre and type, last 12 months
SELECT pc.centre_name, i.incident_type, COUNT(*) AS incidents,
       COUNT_IF(i.severity IN ('High', 'Critical')) AS serious
FROM PUBLIC.INCIDENT_LOG i
JOIN PUBLIC.PROFIT_CENTRES pc ON pc.profit_centre_id = i.profit_centre_id
WHERE i.incident_date > '2025-10-31'
GROUP BY 1, 2
ORDER BY incidents DESC;

-- T13 Assessor recommendations by period (commercial view, context only)
SELECT assessment_period, recommendation, COUNT(*) AS assessments
FROM PUBLIC.SUPPLIER_ASSESSMENTS
WHERE assessment_period IN ('H1-FY2026', 'H2-FY2026')
GROUP BY 1, 2
ORDER BY 1, 2;

-- T14 Supplier compliance overview
SELECT category, compliance_status, COUNT(*) AS suppliers
FROM PUBLIC.SUPPLIERS
GROUP BY 1, 2
ORDER BY 1, 2;

-- -----------------------------------------------------------------------------
-- Persona: contracts_manager
-- -----------------------------------------------------------------------------
ALTER SESSION SET QUERY_TAG = '{"team":"procurement","persona":"contracts_manager","tool":"worksheet"}';

-- T15 Expiring soon (Renewal Process s3): Active, not Auto-renew, ending within 90 days of 31 Oct 2026
SELECT c.contract_id, s.supplier_name, c.contract_type, c.renewal_type, c.end_date, c.contract_value
FROM PUBLIC.CONTRACTS c
JOIN PUBLIC.SUPPLIERS s ON s.supplier_id = c.supplier_id
WHERE c.contract_status = 'Active'
  AND c.renewal_type <> 'Auto-renew'
  AND c.end_date BETWEEN '2026-10-31' AND DATEADD(day, 90, '2026-10-31'::DATE)
ORDER BY c.end_date;

-- T16 Contract register by status and renewal type
SELECT contract_status, renewal_type, COUNT(*) AS contracts, ROUND(SUM(contract_value), 2) AS total_value
FROM PUBLIC.CONTRACTS
GROUP BY 1, 2
ORDER BY 1, 2;

-- T17 Active contract value by supplier category
SELECT s.category, COUNT(*) AS active_contracts, ROUND(SUM(c.contract_value), 2) AS active_value
FROM PUBLIC.CONTRACTS c
JOIN PUBLIC.SUPPLIERS s ON s.supplier_id = c.supplier_id
WHERE c.contract_status = 'Active'
GROUP BY 1
ORDER BY active_value DESC;

-- T18 Renewal tracker (Under Renewal)
SELECT s.supplier_name, c.contract_type, c.end_date, c.contract_value
FROM PUBLIC.CONTRACTS c
JOIN PUBLIC.SUPPLIERS s ON s.supplier_id = c.supplier_id
WHERE c.contract_status = 'Under Renewal'
ORDER BY c.end_date;

-- -----------------------------------------------------------------------------
-- Persona: finance_analyst
-- -----------------------------------------------------------------------------
ALTER SESSION SET QUERY_TAG = '{"team":"finance","persona":"finance_analyst","tool":"worksheet"}';

-- T19 Budget vs actual by state
SELECT pc.state, ROUND(SUM(b.budget_amount), 2) AS budget, ROUND(SUM(b.actual_spend), 2) AS actual,
       ROUND(SUM(b.variance), 2) AS variance
FROM ANALYTICS.BUDGET_ACTUALS_VW b
JOIN PUBLIC.PROFIT_CENTRES pc ON pc.profit_centre_id = b.profit_centre_id
WHERE b.financial_year = 'FY2026'
GROUP BY 1
ORDER BY variance;

-- T20 Material overruns (Budget Governance s5): over by > 10% AND > $50,000
SELECT pc.centre_name, g.gl_account_name, b.financial_year, b.budget_amount, b.actual_spend,
       b.actual_spend - b.budget_amount AS overrun
FROM ANALYTICS.BUDGET_ACTUALS_VW b
JOIN PUBLIC.PROFIT_CENTRES pc ON pc.profit_centre_id = b.profit_centre_id
JOIN PUBLIC.GL_HIERARCHY g ON g.gl_account_id = b.gl_account_id
WHERE b.financial_year = 'FY2026'
  AND b.actual_spend > 1.10 * b.budget_amount
  AND b.actual_spend - b.budget_amount > 50000
ORDER BY overrun DESC;

-- T21 Budget status by GL category
SELECT gl_category, budget_status, COUNT(*) AS lines
FROM ANALYTICS.BUDGET_ACTUALS_VW
WHERE financial_year = 'FY2026'
GROUP BY 1, 2
ORDER BY 1, 2;

-- T22 Spend per FTE by centre (FTE = average monthly FTE, never summed across months)
WITH spend AS (
  SELECT profit_centre_id, SUM(amount) AS spend
  FROM PUBLIC.PO_TRANSACTIONS
  WHERE status = 'Approved' AND financial_year = 'FY2026'
  GROUP BY 1
), fte AS (
  SELECT profit_centre_id, SUM(fte_equivalent) / COUNT(DISTINCT month) AS avg_fte
  FROM PUBLIC.STAFF_ROSTER
  WHERE month BETWEEN '2025-07-01' AND '2026-06-01'
  GROUP BY 1
)
SELECT pc.centre_name, pc.centre_size, ROUND(s.spend, 2) AS spend, ROUND(f.avg_fte, 1) AS avg_fte,
       ROUND(s.spend / f.avg_fte, 2) AS spend_per_fte
FROM spend s JOIN fte f USING (profit_centre_id)
JOIN PUBLIC.PROFIT_CENTRES pc USING (profit_centre_id)
ORDER BY spend_per_fte DESC;

-- T23 Staff cost by role
SELECT role_type, ROUND(SUM(total_cost), 2) AS staff_cost, ROUND(SUM(hours_worked), 1) AS hours
FROM PUBLIC.STAFF_COSTS
WHERE month BETWEEN '2025-07-01' AND '2026-06-01'
GROUP BY 1
ORDER BY staff_cost DESC;

-- T24 Average monthly headcount by centre
SELECT pc.centre_name, ROUND(SUM(r.headcount) / COUNT(DISTINCT r.month), 1) AS avg_monthly_headcount
FROM PUBLIC.STAFF_ROSTER r
JOIN PUBLIC.PROFIT_CENTRES pc ON pc.profit_centre_id = r.profit_centre_id
WHERE r.month BETWEEN '2025-07-01' AND '2026-06-01'
GROUP BY 1
ORDER BY 2 DESC;

-- -----------------------------------------------------------------------------
-- Persona: facilities_manager
-- -----------------------------------------------------------------------------
ALTER SESSION SET QUERY_TAG = '{"team":"operations","persona":"facilities_manager","tool":"worksheet"}';

-- T25 Active assets under warranty, by warranty supplier and category
SELECT s.supplier_name, a.asset_category, COUNT(*) AS assets, ROUND(SUM(a.purchase_cost), 2) AS asset_value
FROM PUBLIC.ASSET_REGISTER a
JOIN PUBLIC.SUPPLIERS s ON s.supplier_id = a.warranty_supplier_id
WHERE a.asset_status = 'Active'
GROUP BY 1, 2
ORDER BY assets DESC;

-- T26 Asset-linked incidents by asset category (warranty claims are handled by Facilities)
SELECT a.asset_category, i.severity, COUNT(*) AS incidents
FROM PUBLIC.INCIDENT_LOG i
JOIN PUBLIC.ASSET_REGISTER a ON a.asset_id = i.related_asset_id
WHERE i.incident_date > '2025-10-31'
GROUP BY 1, 2
ORDER BY 1, 2;

-- -----------------------------------------------------------------------------
-- Persona: procurement_ops
-- -----------------------------------------------------------------------------
ALTER SESSION SET QUERY_TAG = '{"team":"procurement","persona":"procurement_ops","tool":"worksheet"}';

-- T27 Procurement email volume by buyer, last 90 days
SELECT b.buyer_name, COUNT(*) AS emails, COUNT(DISTINCT e.thread_id) AS threads
FROM PUBLIC.PROCUREMENT_EMAILS e
JOIN PUBLIC.BUYERS b ON b.email = e.sender_email
WHERE e.email_date > DATEADD(day, -90, '2026-10-31'::DATE)
GROUP BY 1
ORDER BY emails DESC;

ALTER SESSION UNSET QUERY_TAG;
