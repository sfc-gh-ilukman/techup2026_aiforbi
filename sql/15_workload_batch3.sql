-- =============================================================================
-- 15_workload_batch3.sql — query workload batch 3 (optional: re-run on another day)
--
-- Run with `python3 scripts/lab.py run 15_workload_batch3` (or a Snowsight worksheet). Building blocks only.
-- =============================================================================

USE ROLE {{ROLE}};
USE WAREHOUSE {{WH}};
USE DATABASE {{DB}};

ALTER SESSION SET QUERY_TAG = '{"team":"procurement","persona":"procurement_analyst","tool":"snowsight"}';

-- T02 Category spend (FY2025)
SELECT s.category, ROUND(SUM(po.amount), 2) AS approved_spend
FROM PUBLIC.PO_TRANSACTIONS po
JOIN PUBLIC.SUPPLIERS s ON s.supplier_id = po.supplier_id
WHERE po.status = 'Approved' AND po.financial_year = 'FY2025'
GROUP BY s.category
ORDER BY approved_spend DESC;

-- T03 Top 10 suppliers by approved spend (FY2026)
SELECT s.supplier_id, s.supplier_name, ROUND(SUM(po.amount), 2) AS approved_spend
FROM PUBLIC.PO_TRANSACTIONS po
JOIN PUBLIC.SUPPLIERS s ON s.supplier_id = po.supplier_id
WHERE po.status = 'Approved' AND po.financial_year = 'FY2026'
GROUP BY 1, 2
ORDER BY approved_spend DESC
LIMIT 10;

-- T04 Tail spend (FY2025)
WITH s AS (
  SELECT supplier_id, SUM(amount) AS spend
  FROM PUBLIC.PO_TRANSACTIONS
  WHERE status = 'Approved' AND financial_year = 'FY2025'
  GROUP BY 1
), c AS (
  SELECT supplier_id, spend,
         SUM(spend) OVER (ORDER BY spend DESC, supplier_id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS spend_before,
         SUM(spend) OVER () AS total
  FROM s
)
SELECT COUNT_IF(COALESCE(spend_before, 0) >= 0.8 * total) AS tail_suppliers,
       ROUND(SUM(IFF(COALESCE(spend_before, 0) >= 0.8 * total, spend, 0)), 2) AS tail_spend
FROM c;

-- T07 Overdue invoices by state
SELECT pc.state, COUNT(*) AS overdue_invoices, ROUND(SUM(i.invoice_amount), 2) AS overdue_amount
FROM PUBLIC.PO_INVOICES i
JOIN PUBLIC.PO_TRANSACTIONS po ON po.po_id = i.po_id
JOIN PUBLIC.PROFIT_CENTRES pc ON pc.profit_centre_id = po.profit_centre_id
WHERE i.payment_status = 'Overdue'
GROUP BY 1
ORDER BY overdue_amount DESC;

ALTER SESSION SET QUERY_TAG = '{"team":"procurement","persona":"supplier_manager","tool":"snowsight"}';

-- T09 Score trend for suppliers below 3.00 in the latest completed period
WITH latest AS (
  SELECT supplier_id, AVG(overall_score) AS score
  FROM PUBLIC.SUPPLIER_ASSESSMENTS
  WHERE assessment_period = 'H2-FY2026'
  GROUP BY 1
  HAVING AVG(overall_score) < 3.00
)
SELECT a.supplier_id, a.assessment_period, ROUND(AVG(a.overall_score), 2) AS supplier_score
FROM PUBLIC.SUPPLIER_ASSESSMENTS a JOIN latest USING (supplier_id)
GROUP BY 1, 2
ORDER BY 1, TO_NUMBER(SUBSTR(a.assessment_period, 6, 4)), TO_NUMBER(SUBSTR(a.assessment_period, 2, 1));

-- T11 Serious PO-linked incidents by month, last 6 months
SELECT DATE_TRUNC('month', i.incident_date) AS month, po.supplier_id, COUNT(*) AS high_critical_incidents
FROM PUBLIC.INCIDENT_LOG i
JOIN PUBLIC.PO_TRANSACTIONS po ON po.po_id = i.related_po_id
WHERE i.severity IN ('High', 'Critical')
  AND i.incident_date BETWEEN '2026-05-01' AND '2026-10-31'
GROUP BY 1, 2
ORDER BY 1, 3 DESC;

-- T12 Incidents by severity and category, last 12 months
SELECT incident_category, severity, COUNT(*) AS incidents
FROM PUBLIC.INCIDENT_LOG
WHERE incident_date > '2025-10-31'
GROUP BY 1, 2
ORDER BY 1, 2;

ALTER SESSION SET QUERY_TAG = '{"team":"procurement","persona":"contracts_manager","tool":"snowsight"}';

-- T15 Expiring soon by owner contract type
SELECT c.contract_type, COUNT(*) AS contracts, ROUND(SUM(c.contract_value), 2) AS value
FROM PUBLIC.CONTRACTS c
WHERE c.contract_status = 'Active' AND c.renewal_type <> 'Auto-renew'
  AND c.end_date BETWEEN '2026-10-31' AND DATEADD(day, 90, '2026-10-31'::DATE)
GROUP BY 1
ORDER BY value DESC;

-- T18 Auto-renew notice register, next 90 days
SELECT s.supplier_name, c.contract_type, c.end_date
FROM PUBLIC.CONTRACTS c
JOIN PUBLIC.SUPPLIERS s ON s.supplier_id = c.supplier_id
WHERE c.contract_status = 'Active' AND c.renewal_type = 'Auto-renew'
  AND c.end_date BETWEEN '2026-10-31' AND DATEADD(day, 90, '2026-10-31'::DATE)
ORDER BY c.end_date;

ALTER SESSION SET QUERY_TAG = '{"team":"finance","persona":"finance_analyst","tool":"snowsight"}';

-- T19 Budget vs actual by GL category (FY2026)
SELECT b.gl_category, ROUND(SUM(b.budget_amount), 2) AS budget, ROUND(SUM(b.actual_spend), 2) AS actual,
       ROUND(SUM(b.variance), 2) AS variance
FROM ANALYTICS.BUDGET_ACTUALS_VW b
WHERE b.financial_year = 'FY2026'
GROUP BY 1
ORDER BY variance;

-- T23 Staff cost by role and state (FY2026)
SELECT pc.state, c.role_type, ROUND(SUM(c.total_cost), 2) AS staff_cost
FROM PUBLIC.STAFF_COSTS c
JOIN PUBLIC.PROFIT_CENTRES pc ON pc.profit_centre_id = c.profit_centre_id
WHERE c.month BETWEEN '2025-07-01' AND '2026-06-01'
GROUP BY 1, 2
ORDER BY 1, 3 DESC;

ALTER SESSION UNSET QUERY_TAG;
