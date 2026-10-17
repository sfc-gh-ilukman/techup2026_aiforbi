# PeakFit Analyst Query Library

| | |
|---|---|
| **Document ID** | PF-ANA-QL-001 |
| **Owner** | Procurement Analytics |
| **Version** | 1.6 |
| **Last reviewed** | 1 October 2026 |
| **Applies to** | Procurement, Finance and Operations analysts |

Reviewed SQL patterns the analytics team uses against `{{DB}}`. Each pattern lists the business question it answers, who uses it, how often it runs and what to watch out for. Copy a pattern and change the parameters (financial year, dates, supplier, centre) as needed.

Conventions used throughout:

- **Spend** = Approved purchase orders only (`STATUS = 'Approved'`). Financial year runs July to June (`FINANCIAL_YEAR = 'FY2026'` = 1 Jul 2025 to 30 Jun 2026).
- Data is **as at 31 October 2026**; date windows are written relative to that date.
- Supplier performance periods (`H1-FY2026`, `H2-FY2026`) are ordered by **financial year, then half**, never as text.

---

## 1. Spend

### QL-01 Approved spend by state for a financial year
- **Question:** How much did each state spend in FY2026?
- **Used by:** Procurement analysts, Finance. **Runs:** weekly.

```sql
SELECT pc.state, ROUND(SUM(po.amount), 2) AS approved_spend, COUNT(*) AS po_count
FROM {{DB}}.PUBLIC.PO_TRANSACTIONS po
JOIN {{DB}}.PUBLIC.PROFIT_CENTRES pc ON pc.profit_centre_id = po.profit_centre_id
WHERE po.status = 'Approved' AND po.financial_year = 'FY2026'
GROUP BY pc.state
ORDER BY approved_spend DESC;
```

### QL-02 Approved spend by centre
- **Question:** Which centres spent the most in FY2026?
- **Used by:** Regional managers. **Runs:** monthly.

```sql
SELECT pc.state, pc.centre_name, ROUND(SUM(po.amount), 2) AS approved_spend
FROM {{DB}}.PUBLIC.PO_TRANSACTIONS po
JOIN {{DB}}.PUBLIC.PROFIT_CENTRES pc ON pc.profit_centre_id = po.profit_centre_id
WHERE po.status = 'Approved' AND po.financial_year = 'FY2026'
GROUP BY 1, 2
ORDER BY approved_spend DESC;
```

### QL-03 Category spend
- **Question:** What was our spend by supplier category in FY2026?
- **Used by:** Category managers. **Runs:** monthly.
- **Note:** category spend groups by the supplier's `CATEGORY`, not by spend code.

```sql
SELECT s.category, ROUND(SUM(po.amount), 2) AS approved_spend
FROM {{DB}}.PUBLIC.PO_TRANSACTIONS po
JOIN {{DB}}.PUBLIC.SUPPLIERS s ON s.supplier_id = po.supplier_id
WHERE po.status = 'Approved' AND po.financial_year = 'FY2026'
GROUP BY s.category
ORDER BY approved_spend DESC;
```

### QL-04 Approved spend by supplier for a financial year
- **Question:** How much did we spend with each supplier in FY2026?
- **Used by:** Procurement analysts, Contracts. **Runs:** weekly; also pulled for every renewal pack.

```sql
SELECT s.supplier_id, s.supplier_name, s.category, ROUND(SUM(po.amount), 2) AS approved_spend
FROM {{DB}}.PUBLIC.PO_TRANSACTIONS po
JOIN {{DB}}.PUBLIC.SUPPLIERS s ON s.supplier_id = po.supplier_id
WHERE po.status = 'Approved' AND po.financial_year = 'FY2026'
GROUP BY 1, 2, 3
ORDER BY approved_spend DESC;
```

### QL-05 Tail spend
- **Question:** How many suppliers and how much spend sit in the tail (after the first 80% of spend)?
- **Used by:** Category managers. **Runs:** quarterly.

```sql
WITH s AS (
  SELECT supplier_id, SUM(amount) AS spend
  FROM {{DB}}.PUBLIC.PO_TRANSACTIONS
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
```

### QL-06 Maverick (off-contract) spend
- **Question:** How much approved spend was with suppliers that had no contract in force on the PO date?
- **Used by:** Procurement analysts. **Runs:** monthly.

```sql
SELECT s.supplier_name, ROUND(SUM(po.amount), 2) AS off_contract_spend, COUNT(*) AS po_count
FROM {{DB}}.PUBLIC.PO_TRANSACTIONS po
JOIN {{DB}}.PUBLIC.SUPPLIERS s ON s.supplier_id = po.supplier_id
WHERE po.status = 'Approved' AND po.financial_year = 'FY2026'
  AND NOT EXISTS (SELECT 1 FROM {{DB}}.PUBLIC.CONTRACTS c
                  WHERE c.supplier_id = po.supplier_id AND po.po_date BETWEEN c.start_date AND c.end_date)
GROUP BY 1
ORDER BY off_contract_spend DESC;
```

### QL-07 Monthly approved spend trend
- **Question:** How is monthly spend trending by state?
- **Used by:** Finance. **Runs:** monthly.

```sql
SELECT DATE_TRUNC('month', po.po_date) AS month, pc.state, ROUND(SUM(po.amount), 2) AS approved_spend
FROM {{DB}}.PUBLIC.PO_TRANSACTIONS po
JOIN {{DB}}.PUBLIC.PROFIT_CENTRES pc ON pc.profit_centre_id = po.profit_centre_id
WHERE po.status = 'Approved' AND po.po_date <= '2026-10-31'
GROUP BY 1, 2
ORDER BY 1, 2;
```

---

## 2. Approvals and compliance

### QL-08 Split-PO review
- **Question:** Which buyers have split-PO patterns in FY2026 (Approval Policy PF-FIN-POL-011 s3)?
- **Used by:** Internal Audit. **Runs:** monthly.
- **Note:** same buyer + supplier + spend code, within 3 days, each $4,000–$5,000, combined over $5,000.

```sql
SELECT b.buyer_name, COUNT(DISTINCT a.po_id) AS flagged_pos
FROM {{DB}}.PUBLIC.PO_TRANSACTIONS a
JOIN {{DB}}.PUBLIC.PO_TRANSACTIONS x
  ON x.buyer_id = a.buyer_id AND x.supplier_id = a.supplier_id AND x.spend_code_id = a.spend_code_id
 AND x.po_id <> a.po_id AND ABS(DATEDIFF(day, a.po_date, x.po_date)) <= 3
JOIN {{DB}}.PUBLIC.BUYERS b ON b.buyer_id = a.buyer_id
WHERE a.status = 'Approved' AND x.status = 'Approved'
  AND a.amount BETWEEN 4000 AND 5000 AND x.amount BETWEEN 4000 AND 5000
  AND a.amount + x.amount > 5000
  AND a.financial_year = 'FY2026'
GROUP BY 1
ORDER BY flagged_pos DESC;
```

### QL-09 Approval level mix by buyer
- **Question:** How are each buyer's FY2026 POs spread across approval levels?
- **Used by:** Internal Audit. **Runs:** quarterly.

```sql
SELECT b.buyer_name, po.approval_level, COUNT(*) AS pos, ROUND(SUM(po.amount), 2) AS value
FROM {{DB}}.PUBLIC.PO_TRANSACTIONS po
JOIN {{DB}}.PUBLIC.BUYERS b ON b.buyer_id = po.buyer_id
WHERE po.financial_year = 'FY2026'
GROUP BY 1, 2
ORDER BY 1, 2;
```

### QL-10 Overdue invoices by supplier
- **Question:** Which suppliers have the most overdue invoice value?
- **Used by:** Accounts payable. **Runs:** weekly.

```sql
SELECT s.supplier_name, COUNT(*) AS overdue_invoices, ROUND(SUM(i.invoice_amount), 2) AS overdue_amount
FROM {{DB}}.PUBLIC.PO_INVOICES i
JOIN {{DB}}.PUBLIC.SUPPLIERS s ON s.supplier_id = i.supplier_id
WHERE i.payment_status = 'Overdue'
GROUP BY 1
ORDER BY overdue_amount DESC;
```

### QL-11 Supplier compliance overview
- **Question:** How many suppliers in each category are compliant?
- **Used by:** Supplier managers. **Runs:** monthly.

```sql
SELECT category, compliance_status, COUNT(*) AS suppliers
FROM {{DB}}.PUBLIC.SUPPLIERS
GROUP BY 1, 2
ORDER BY 1, 2;
```

---

## 3. Supplier performance

### QL-12 Supplier performance score by period
- **Question:** What is each supplier's performance score per half-year?
- **Used by:** Supplier managers. **Runs:** weekly.
- **Note:** the supplier score for a period is the **average across all centres** that assessed it. Order periods by FY then half; sorting the labels as text puts `H2-FY2025` after `H1-FY2026`.

```sql
SELECT supplier_id, assessment_period,
       ROUND(AVG(overall_score), 2) AS supplier_score, COUNT(*) AS centres_assessed
FROM {{DB}}.PUBLIC.SUPPLIER_ASSESSMENTS
GROUP BY 1, 2
ORDER BY supplier_id,
         TO_NUMBER(SUBSTR(assessment_period, 6, 4)), TO_NUMBER(SUBSTR(assessment_period, 2, 1));
```

### QL-13 Sustained poor performance (two latest completed periods)
- **Question:** Which suppliers scored below 3.00 in each of the two most recent completed periods?
- **Used by:** Supplier managers (monthly at-risk review, rule (a) of PF-PROC-SMP-004). **Runs:** monthly.

```sql
WITH p AS (
  SELECT DISTINCT assessment_period,
         TO_NUMBER(SUBSTR(assessment_period, 6, 4)) * 10 + TO_NUMBER(SUBSTR(assessment_period, 2, 1)) AS ord
  FROM {{DB}}.PUBLIC.SUPPLIER_ASSESSMENTS
), last2 AS (
  SELECT assessment_period FROM p QUALIFY ROW_NUMBER() OVER (ORDER BY ord DESC) <= 2
), s AS (
  SELECT a.supplier_id, a.assessment_period, AVG(a.overall_score) AS supplier_score
  FROM {{DB}}.PUBLIC.SUPPLIER_ASSESSMENTS a JOIN last2 USING (assessment_period)
  GROUP BY 1, 2
)
SELECT supplier_id, ROUND(MIN(supplier_score), 2) AS min_score, ROUND(MAX(supplier_score), 2) AS max_score
FROM s
GROUP BY 1
HAVING COUNT(*) = 2 AND MAX(supplier_score) < 3.00
ORDER BY 1;
```

### QL-14 Serious incidents attributed to suppliers, last 6 months
- **Question:** How many High/Critical incidents has each supplier had in the last six months?
- **Used by:** Supplier managers (rule (b) of PF-PROC-SMP-004), Facilities. **Runs:** weekly.
- **Note:** attribute incidents through the **related purchase order** (`RELATED_PO_ID` → PO `SUPPLIER_ID`). Asset-only incidents are not supplier incidents, even when the asset is under a supplier's warranty.

```sql
SELECT po.supplier_id, s.supplier_name, COUNT(*) AS high_critical_incidents
FROM {{DB}}.PUBLIC.INCIDENT_LOG i
JOIN {{DB}}.PUBLIC.PO_TRANSACTIONS po ON po.po_id = i.related_po_id
JOIN {{DB}}.PUBLIC.SUPPLIERS s ON s.supplier_id = po.supplier_id
WHERE i.severity IN ('High', 'Critical')
  AND i.incident_date BETWEEN '2026-05-01' AND '2026-10-31'
GROUP BY 1, 2
ORDER BY high_critical_incidents DESC;
```

### QL-15 Incidents by centre and type, last 12 months
- **Question:** Where are incidents happening and how serious are they?
- **Used by:** Operations. **Runs:** monthly.

```sql
SELECT pc.centre_name, i.incident_type, COUNT(*) AS incidents,
       COUNT_IF(i.severity IN ('High', 'Critical')) AS serious
FROM {{DB}}.PUBLIC.INCIDENT_LOG i
JOIN {{DB}}.PUBLIC.PROFIT_CENTRES pc ON pc.profit_centre_id = i.profit_centre_id
WHERE i.incident_date > '2025-10-31'
GROUP BY 1, 2
ORDER BY incidents DESC;
```

### QL-16 Assessor recommendations by period
- **Question:** What are assessors recommending this year?
- **Used by:** Category managers. **Runs:** half-yearly.
- **Note:** the recommendation is a commercial view (often price-driven) and is **not** used to decide at-risk status.

```sql
SELECT assessment_period, recommendation, COUNT(*) AS assessments
FROM {{DB}}.PUBLIC.SUPPLIER_ASSESSMENTS
WHERE assessment_period IN ('H1-FY2026', 'H2-FY2026')
GROUP BY 1, 2
ORDER BY 1, 2;
```

### QL-17 Supplier Risk Score inputs
- **Question:** What feeds a supplier's Risk Score on the scorecard?
- **Used by:** Supplier managers. **Runs:** ad hoc.
- **Note:** the 0–100 Supplier Risk Score is calculated in the PeakFit Procurement Insights app. It is a dashboard indicator; **at-risk status is defined separately** in PF-PROC-SMP-004.

```sql
SELECT s.supplier_id, s.supplier_name,
       (SELECT ROUND(AVG(a.overall_score), 2) FROM {{DB}}.PUBLIC.SUPPLIER_ASSESSMENTS a
         WHERE a.supplier_id = s.supplier_id AND a.assessment_period IN ('H1-FY2026', 'H2-FY2026')) AS avg_score_last_2_periods,
       (SELECT ROUND(SUM(IFF(i.payment_status = 'Overdue', i.invoice_amount, 0)) / NULLIF(SUM(i.invoice_amount), 0), 4)
          FROM {{DB}}.PUBLIC.PO_INVOICES i
         WHERE i.supplier_id = s.supplier_id AND i.invoice_date > '2025-10-31') AS overdue_ratio_12m
FROM {{DB}}.PUBLIC.SUPPLIERS s
ORDER BY 1;
```

---

## 4. Contracts

### QL-18 Contracts expiring soon
- **Question:** Which contracts are expiring soon (Contract Renewal Process PF-PROC-CRP-002 s3)?
- **Used by:** Contracts manager. **Runs:** weekly.
- **Note:** Active only, not Auto-renew, ending within 90 days of the review date (31 Oct 2026 to 29 Jan 2027). Under Renewal contracts are on the renewal tracker instead.

```sql
SELECT c.contract_id, s.supplier_name, c.contract_type, c.renewal_type, c.end_date, c.contract_value
FROM {{DB}}.PUBLIC.CONTRACTS c
JOIN {{DB}}.PUBLIC.SUPPLIERS s ON s.supplier_id = c.supplier_id
WHERE c.contract_status = 'Active'
  AND c.renewal_type <> 'Auto-renew'
  AND c.end_date BETWEEN '2026-10-31' AND DATEADD(day, 90, '2026-10-31'::DATE)
ORDER BY c.end_date;
```

### QL-19 Renewal prep: expiring-soon suppliers with last FY spend
- **Question:** For suppliers with contracts expiring soon, what did we spend with them in the last complete FY?
- **Used by:** Contracts manager (renewal packs). **Runs:** monthly.

```sql
WITH expiring AS (
  SELECT supplier_id, MIN(end_date) AS next_expiry, COUNT(*) AS contracts
  FROM {{DB}}.PUBLIC.CONTRACTS
  WHERE contract_status = 'Active' AND renewal_type <> 'Auto-renew'
    AND end_date BETWEEN '2026-10-31' AND DATEADD(day, 90, '2026-10-31'::DATE)
  GROUP BY 1
)
SELECT s.supplier_name, e.next_expiry, e.contracts, ROUND(SUM(po.amount), 2) AS fy2026_approved_spend
FROM expiring e
JOIN {{DB}}.PUBLIC.SUPPLIERS s ON s.supplier_id = e.supplier_id
LEFT JOIN {{DB}}.PUBLIC.PO_TRANSACTIONS po
  ON po.supplier_id = e.supplier_id AND po.status = 'Approved' AND po.financial_year = 'FY2026'
GROUP BY 1, 2, 3
ORDER BY fy2026_approved_spend DESC;
```

### QL-20 Renewal tracker
- **Question:** Which contracts are currently under renewal?
- **Used by:** Contracts manager. **Runs:** weekly.

```sql
SELECT s.supplier_name, c.contract_type, c.end_date, c.contract_value
FROM {{DB}}.PUBLIC.CONTRACTS c
JOIN {{DB}}.PUBLIC.SUPPLIERS s ON s.supplier_id = c.supplier_id
WHERE c.contract_status = 'Under Renewal'
ORDER BY c.end_date;
```

### QL-21 Auto-renew notice register
- **Question:** Which Auto-renew contracts roll over in the next 90 days (notice decisions)?
- **Used by:** Contracts manager. **Runs:** monthly.

```sql
SELECT s.supplier_name, c.contract_type, c.end_date
FROM {{DB}}.PUBLIC.CONTRACTS c
JOIN {{DB}}.PUBLIC.SUPPLIERS s ON s.supplier_id = c.supplier_id
WHERE c.contract_status = 'Active' AND c.renewal_type = 'Auto-renew'
  AND c.end_date BETWEEN '2026-10-31' AND DATEADD(day, 90, '2026-10-31'::DATE)
ORDER BY c.end_date;
```

### QL-22 Contract register summary
- **Question:** How many contracts do we hold by status and renewal type?
- **Used by:** Head of Procurement. **Runs:** quarterly.

```sql
SELECT contract_status, renewal_type, COUNT(*) AS contracts, ROUND(SUM(contract_value), 2) AS total_value
FROM {{DB}}.PUBLIC.CONTRACTS
GROUP BY 1, 2
ORDER BY 1, 2;
```

---

## 5. Budget and workforce

### QL-23 Budget vs actual by state
- **Question:** How did each state track against budget in FY2026?
- **Used by:** Finance. **Runs:** monthly.
- **Note:** variance = budget − actual; negative means overspend.

```sql
SELECT pc.state, ROUND(SUM(b.budget_amount), 2) AS budget, ROUND(SUM(b.actual_spend), 2) AS actual,
       ROUND(SUM(b.variance), 2) AS variance
FROM {{DB}}.ANALYTICS.BUDGET_ACTUALS_VW b
JOIN {{DB}}.PUBLIC.PROFIT_CENTRES pc ON pc.profit_centre_id = b.profit_centre_id
WHERE b.financial_year = 'FY2026'
GROUP BY 1
ORDER BY variance;
```

### QL-24 Material overruns
- **Question:** Which budget lines had a material overrun in FY2026 (Budget Governance PF-FIN-STD-006 s5)?
- **Used by:** Financial Controller. **Runs:** at year-end close.
- **Note:** both conditions are required: over by more than 10% **and** by more than $50,000.

```sql
SELECT pc.centre_name, g.gl_account_name, b.financial_year, b.budget_amount, b.actual_spend,
       b.actual_spend - b.budget_amount AS overrun
FROM {{DB}}.ANALYTICS.BUDGET_ACTUALS_VW b
JOIN {{DB}}.PUBLIC.PROFIT_CENTRES pc ON pc.profit_centre_id = b.profit_centre_id
JOIN {{DB}}.PUBLIC.GL_HIERARCHY g ON g.gl_account_id = b.gl_account_id
WHERE b.financial_year = 'FY2026'
  AND b.actual_spend > 1.10 * b.budget_amount
  AND b.actual_spend - b.budget_amount > 50000
ORDER BY overrun DESC;
```

### QL-25 Spend per FTE by centre
- **Question:** What is procurement spend per FTE for each centre in FY2026?
- **Used by:** Finance, Regional managers. **Runs:** quarterly.
- **Note:** FTE is the **average monthly** FTE; never sum headcount or FTE across months.

```sql
WITH spend AS (
  SELECT profit_centre_id, SUM(amount) AS spend
  FROM {{DB}}.PUBLIC.PO_TRANSACTIONS
  WHERE status = 'Approved' AND financial_year = 'FY2026'
  GROUP BY 1
), fte AS (
  SELECT profit_centre_id, SUM(fte_equivalent) / COUNT(DISTINCT month) AS avg_fte
  FROM {{DB}}.PUBLIC.STAFF_ROSTER
  WHERE month BETWEEN '2025-07-01' AND '2026-06-01'
  GROUP BY 1
)
SELECT pc.centre_name, pc.centre_size, ROUND(s.spend, 2) AS spend, ROUND(f.avg_fte, 1) AS avg_fte,
       ROUND(s.spend / f.avg_fte, 2) AS spend_per_fte
FROM spend s JOIN fte f USING (profit_centre_id)
JOIN {{DB}}.PUBLIC.PROFIT_CENTRES pc USING (profit_centre_id)
ORDER BY spend_per_fte DESC;
```

### QL-26 Staff cost by role
- **Question:** What did each role cost in FY2026?
- **Used by:** HR, Finance. **Runs:** monthly.

```sql
SELECT role_type, ROUND(SUM(total_cost), 2) AS staff_cost, ROUND(SUM(hours_worked), 1) AS hours
FROM {{DB}}.PUBLIC.STAFF_COSTS
WHERE month BETWEEN '2025-07-01' AND '2026-06-01'
GROUP BY 1
ORDER BY staff_cost DESC;
```

---

## 6. Facilities and operations

### QL-27 Active assets under warranty by supplier
- **Question:** Which suppliers hold warranties on our active assets?
- **Used by:** Facilities. **Runs:** quarterly.
- **Note:** warranty claims are managed by Facilities through the warranty register; they are separate from supplier performance.

```sql
SELECT s.supplier_name, a.asset_category, COUNT(*) AS assets, ROUND(SUM(a.purchase_cost), 2) AS asset_value
FROM {{DB}}.PUBLIC.ASSET_REGISTER a
JOIN {{DB}}.PUBLIC.SUPPLIERS s ON s.supplier_id = a.warranty_supplier_id
WHERE a.asset_status = 'Active'
GROUP BY 1, 2
ORDER BY assets DESC;
```

### QL-28 Asset-linked incidents by category
- **Question:** Which asset categories are generating incidents?
- **Used by:** Facilities. **Runs:** monthly.

```sql
SELECT a.asset_category, i.severity, COUNT(*) AS incidents
FROM {{DB}}.PUBLIC.INCIDENT_LOG i
JOIN {{DB}}.PUBLIC.ASSET_REGISTER a ON a.asset_id = i.related_asset_id
WHERE i.incident_date > '2025-10-31'
GROUP BY 1, 2
ORDER BY 1, 2;
```

### QL-29 Procurement email volume by buyer
- **Question:** Which buyers are handling the most procurement email in the last 90 days?
- **Used by:** Procurement operations. **Runs:** monthly.

```sql
SELECT b.buyer_name, COUNT(*) AS emails, COUNT(DISTINCT e.thread_id) AS threads
FROM {{DB}}.PUBLIC.PROCUREMENT_EMAILS e
JOIN {{DB}}.PUBLIC.BUYERS b ON b.email = e.sender_email
WHERE e.email_date > DATEADD(day, -90, '2026-10-31'::DATE)
GROUP BY 1
ORDER BY emails DESC;
```
