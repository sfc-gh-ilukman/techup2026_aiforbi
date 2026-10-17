-- =============================================================================
-- 14_workload_batch2.sql — query workload batch 2 (optional: re-run on a later day for a richer history)
--
-- Run with `python3 scripts/lab.py run 14_workload_batch2` (or a Snowsight worksheet), so the queries are
-- user-run with the persona QUERY_TAGs below. Same templates as batch 1 with
-- different parameters; building blocks only, never the full Q2 answer.
-- =============================================================================

USE ROLE {{ROLE}};
USE WAREHOUSE {{WH}};
USE DATABASE {{DB}};

ALTER SESSION SET QUERY_TAG = '{"team":"procurement","persona":"procurement_analyst","tool":"snowsight"}';

-- T01 Approved spend by state (FY2024)
SELECT pc.state, ROUND(SUM(po.amount), 2) AS approved_spend, COUNT(*) AS po_count
FROM PUBLIC.PO_TRANSACTIONS po
JOIN PUBLIC.PROFIT_CENTRES pc ON pc.profit_centre_id = po.profit_centre_id
WHERE po.status = 'Approved' AND po.financial_year = 'FY2024'
GROUP BY pc.state
ORDER BY approved_spend DESC;

-- T01b Approved spend by centre within a state (FY2026, VIC)
SELECT pc.centre_name, ROUND(SUM(po.amount), 2) AS approved_spend
FROM PUBLIC.PO_TRANSACTIONS po
JOIN PUBLIC.PROFIT_CENTRES pc ON pc.profit_centre_id = po.profit_centre_id
WHERE po.status = 'Approved' AND po.financial_year = 'FY2026' AND pc.state = 'VIC'
GROUP BY 1
ORDER BY approved_spend DESC;

-- T03 Approved spend by supplier (FY2026, Equipment Servicing)
SELECT s.supplier_id, s.supplier_name, ROUND(SUM(po.amount), 2) AS approved_spend
FROM PUBLIC.PO_TRANSACTIONS po
JOIN PUBLIC.SUPPLIERS s ON s.supplier_id = po.supplier_id
WHERE po.status = 'Approved' AND po.financial_year = 'FY2026' AND s.category = 'Equipment Servicing'
GROUP BY 1, 2
ORDER BY approved_spend DESC;

-- T05 Maverick spend (FY2025)
SELECT s.supplier_name, ROUND(SUM(po.amount), 2) AS off_contract_spend, COUNT(*) AS po_count
FROM PUBLIC.PO_TRANSACTIONS po
JOIN PUBLIC.SUPPLIERS s ON s.supplier_id = po.supplier_id
WHERE po.status = 'Approved' AND po.financial_year = 'FY2025'
  AND NOT EXISTS (SELECT 1 FROM PUBLIC.CONTRACTS c
                  WHERE c.supplier_id = po.supplier_id AND po.po_date BETWEEN c.start_date AND c.end_date)
GROUP BY 1
ORDER BY off_contract_spend DESC;

-- T06 Split-PO review (FY2025)
SELECT b.buyer_name, COUNT(DISTINCT a.po_id) AS flagged_pos
FROM PUBLIC.PO_TRANSACTIONS a
JOIN PUBLIC.PO_TRANSACTIONS x
  ON x.buyer_id = a.buyer_id AND x.supplier_id = a.supplier_id AND x.spend_code_id = a.spend_code_id
 AND x.po_id <> a.po_id AND ABS(DATEDIFF(day, a.po_date, x.po_date)) <= 3
JOIN PUBLIC.BUYERS b ON b.buyer_id = a.buyer_id
WHERE a.status = 'Approved' AND x.status = 'Approved'
  AND a.amount BETWEEN 4000 AND 5000 AND x.amount BETWEEN 4000 AND 5000
  AND a.amount + x.amount > 5000
  AND a.financial_year = 'FY2025'
GROUP BY 1
ORDER BY flagged_pos DESC;

ALTER SESSION SET QUERY_TAG = '{"team":"procurement","persona":"supplier_manager","tool":"snowsight"}';

-- T09 Supplier score by period for one category
SELECT a.supplier_id, s.supplier_name, a.assessment_period, ROUND(AVG(a.overall_score), 2) AS supplier_score
FROM PUBLIC.SUPPLIER_ASSESSMENTS a
JOIN PUBLIC.SUPPLIERS s ON s.supplier_id = a.supplier_id
WHERE s.category = 'HVAC Services'
GROUP BY 1, 2, 3
ORDER BY 1, TO_NUMBER(SUBSTR(a.assessment_period, 6, 4)), TO_NUMBER(SUBSTR(a.assessment_period, 2, 1));

-- T10 Sustained poor performance (latest two completed periods, ordered FY then half)
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
SELECT s.supplier_id, sp.supplier_name, ROUND(MAX(s.supplier_score), 2) AS best_recent_score
FROM s JOIN PUBLIC.SUPPLIERS sp ON sp.supplier_id = s.supplier_id
GROUP BY 1, 2
HAVING COUNT(*) = 2 AND MAX(s.supplier_score) < 3.00
ORDER BY best_recent_score;

-- T11 Serious PO-linked incidents, last 6 months, by supplier and type
SELECT po.supplier_id, i.incident_type, COUNT(*) AS high_critical_incidents
FROM PUBLIC.INCIDENT_LOG i
JOIN PUBLIC.PO_TRANSACTIONS po ON po.po_id = i.related_po_id
WHERE i.severity IN ('High', 'Critical')
  AND i.incident_date BETWEEN '2026-05-01' AND '2026-10-31'
GROUP BY 1, 2
ORDER BY high_critical_incidents DESC;

ALTER SESSION SET QUERY_TAG = '{"team":"procurement","persona":"contracts_manager","tool":"snowsight"}';

-- T15 Expiring soon with FY2026 approved spend for the supplier (renewal prep)
WITH expiring AS (
  SELECT supplier_id, MIN(end_date) AS next_expiry, COUNT(*) AS contracts
  FROM PUBLIC.CONTRACTS
  WHERE contract_status = 'Active' AND renewal_type <> 'Auto-renew'
    AND end_date BETWEEN '2026-10-31' AND DATEADD(day, 90, '2026-10-31'::DATE)
  GROUP BY 1
)
SELECT s.supplier_name, e.next_expiry, e.contracts, ROUND(SUM(po.amount), 2) AS fy2026_approved_spend
FROM expiring e
JOIN PUBLIC.SUPPLIERS s ON s.supplier_id = e.supplier_id
LEFT JOIN PUBLIC.PO_TRANSACTIONS po
  ON po.supplier_id = e.supplier_id AND po.status = 'Approved' AND po.financial_year = 'FY2026'
GROUP BY 1, 2, 3
ORDER BY fy2026_approved_spend DESC;

-- T16 Contracts ending per month, next 6 months
SELECT DATE_TRUNC('month', end_date) AS end_month, contract_status, renewal_type, COUNT(*) AS contracts
FROM PUBLIC.CONTRACTS
WHERE end_date BETWEEN '2026-10-31' AND '2027-04-30'
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

ALTER SESSION SET QUERY_TAG = '{"team":"finance","persona":"finance_analyst","tool":"snowsight"}';

-- T20 Material overruns (FY2025)
SELECT pc.centre_name, g.gl_account_name, b.budget_amount, b.actual_spend, b.actual_spend - b.budget_amount AS overrun
FROM ANALYTICS.BUDGET_ACTUALS_VW b
JOIN PUBLIC.PROFIT_CENTRES pc ON pc.profit_centre_id = b.profit_centre_id
JOIN PUBLIC.GL_HIERARCHY g ON g.gl_account_id = b.gl_account_id
WHERE b.financial_year = 'FY2025'
  AND b.actual_spend > 1.10 * b.budget_amount
  AND b.actual_spend - b.budget_amount > 50000
ORDER BY overrun DESC;

-- T22 Spend per FTE by centre size (FY2025)
WITH spend AS (
  SELECT profit_centre_id, SUM(amount) AS spend
  FROM PUBLIC.PO_TRANSACTIONS
  WHERE status = 'Approved' AND financial_year = 'FY2025'
  GROUP BY 1
), fte AS (
  SELECT profit_centre_id, SUM(fte_equivalent) / COUNT(DISTINCT month) AS avg_fte
  FROM PUBLIC.STAFF_ROSTER
  WHERE month BETWEEN '2024-07-01' AND '2025-06-01'
  GROUP BY 1
)
SELECT pc.centre_size, ROUND(SUM(s.spend) / SUM(f.avg_fte), 2) AS spend_per_fte
FROM spend s JOIN fte f USING (profit_centre_id)
JOIN PUBLIC.PROFIT_CENTRES pc USING (profit_centre_id)
GROUP BY 1
ORDER BY 2 DESC;

ALTER SESSION UNSET QUERY_TAG;
