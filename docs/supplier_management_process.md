# Supplier Management Process

| | |
|---|---|
| **Document ID** | PF-PROC-SMP-004 |
| **Owner** | Head of Procurement |
| **Version** | 4.2 |
| **Effective date** | 1 July 2025 |
| **Review cycle** | Annual |
| **Applies to** | All PeakFit centres, Procurement, Category Managers |

## 1. Purpose

This process defines how PeakFit assesses supplier performance, identifies suppliers that put service delivery at risk, and escalates them before contract decisions are made.

## 2. Assessment cycle

1. Supplier performance is assessed **half-yearly** at each centre that used the supplier during the half.
   - **H1** = July to December (first half of the financial year).
   - **H2** = January to June (second half of the financial year).
   - Periods are labelled `H1-FY2026`, `H2-FY2026`, and so on. FY2026 runs 1 July 2025 to 30 June 2026.
2. A centre assesses a supplier for a period when it raised at least eight approved purchase orders with that supplier during the half.
3. Each assessment scores four criteria from 1.00 (poor) to 5.00 (excellent): quality, timeliness, communication and value for money. The overall score is the mean of the four.
4. Assessments are completed within six weeks of the half-year closing. **A period counts as completed only once the half-year has ended**; an in-progress half is never used for risk decisions.

## 3. Supplier performance score

A supplier is assessed by several centres each period. The **supplier performance score** for a period is the **average of the overall scores from every centre that assessed the supplier in that period**. Individual centre scores are not used on their own for risk decisions; one poor review at one centre does not make a supplier at risk.

### 3.1 Ordering periods

When identifying the "most recent" periods, order periods by **financial year first, then half** (H1 before H2 within the same financial year). Do **not** sort the period labels as text: alphabetically, `H2-FY2025` sorts after `H1-FY2026`, which gives the wrong two periods.

Example: as at 31 October 2026, the two most recent completed periods are **H1-FY2026** (Jul–Dec 2025) and **H2-FY2026** (Jan–Jun 2026). H1-FY2027 is still in progress.

## 4. At-risk suppliers

A supplier is **at risk** when **either** of the following is true:

| Rule | Condition |
|---|---|
| **(a) Sustained poor performance** | The supplier performance score (Section 3) is **below 3.00 in each of the two most recent completed periods**. A score below 3.00 in only one of the two periods is a watch item, not at risk. |
| **(b) Repeated serious incidents** | **Three or more High or Critical incidents in the last six months** are attributed to the supplier. |

### 4.1 Attributing incidents to a supplier

An incident is attributed to a supplier only when it is logged against a **purchase order** for that supplier's work (the incident's related PO, whose supplier is the supplier on that PO).

Incidents that are linked only to an **asset** are **not** attributed to a supplier, even when the asset is covered by that supplier's warranty. Warranty claims are managed separately by Facilities through the warranty register.

### 4.2 What does not make a supplier at risk

- The assessor's **recommendation** (Preferred / Approved / Conditional / Not Recommended) is a commercial view on future engagement, often driven by pricing. It is recorded for context but is **not** used to determine at-risk status.
- Compliance status (insurance, ABN, safety documents) is managed under the Supplier Compliance Procedure, not this process.

## 5. Escalation

1. Category Managers review the at-risk list each month.
2. Every at-risk supplier must have a remediation plan within 30 days.
3. **An at-risk supplier's contract may not be renewed without Head of Procurement sign-off.** At-risk suppliers with contracts expiring soon are reported on the At-Risk Renewal Watchlist (see the Contract Renewal Process, PF-PROC-CRP-002).
4. A supplier leaves the at-risk list when neither rule applies at the next monthly review.

## 6. Reporting notes (for analysts)

| Item | Source |
|---|---|
| Centre-level assessments | Supplier assessment register (`SUPPLIER_ASSESSMENTS`): one row per supplier, centre and period, with `OVERALL_SCORE` and `ASSESSMENT_PERIOD` |
| Incidents | Incident log (`INCIDENT_LOG`): `SEVERITY`, `INCIDENT_DATE`; supplier attribution via `RELATED_PO_ID` → purchase order `SUPPLIER_ID` |
| "Last six months" | The six months up to and including the review date (as at 31 Oct 2026: incidents dated 1 May 2026 to 31 Oct 2026) |
