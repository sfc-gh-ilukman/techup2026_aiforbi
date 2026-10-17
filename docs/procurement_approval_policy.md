# Procurement Approval Policy

| | |
|---|---|
| **Document ID** | PF-FIN-POL-011 |
| **Owner** | Chief Financial Officer |
| **Version** | 3.0 |
| **Effective date** | 1 July 2024 |
| **Review cycle** | Annual |
| **Applies to** | All staff who raise or approve purchase orders |

## 1. Purpose

This policy sets the approval required before PeakFit commits to spend with a supplier, and the controls that stop approval limits being bypassed.

## 2. Approval thresholds

Every purchase order is approved at the level required by its total value (AUD, excluding GST):

| PO value | Approval level |
|---|---|
| Up to $5,000 | **Self**: the raising buyer approves within their delegation |
| $5,000.01 to $50,000 | **Manager**: Centre Manager or Regional Manager |
| $50,000.01 to $250,000 | **Executive**: COO or CFO |
| Over $250,000 | **LT Panel**: Leadership Team panel |

Only **Approved** purchase orders count as committed spend. Pending and Rejected purchase orders are excluded from all spend reporting.

## 3. PO splitting

**PO splitting** is breaking one purchase into several smaller purchase orders so that each stays within the buyer's Self approval limit. It is a breach of this policy.

For monitoring purposes, Internal Audit flags a **split-PO pattern** when **all** of the following are true:

1. Two or more **Approved** purchase orders are raised by the **same buyer**, to the **same supplier**, on the **same spend code**.
2. The purchase orders are raised **within 3 days** of each other.
3. **Each** purchase order is between **$4,000 and $5,000** (just under the $5,000 Self limit).
4. Their **combined** value is **more than $5,000**.

Flagged patterns are reviewed by the buyer's manager. Repeat patterns are escalated to the CFO.

## 4. Exceptions

1. Emergency repairs affecting member safety may be raised and approved after the event within 2 business days, at the level that would have applied.
2. Utilities and statutory charges are approved through the accounts payable workflow and are exempt from the split-PO review.

## 5. Reporting notes (for analysts)

| Item | Source |
|---|---|
| Purchase orders | `PO_TRANSACTIONS`: `BUYER_ID`, `SUPPLIER_ID`, `SPEND_CODE_ID`, `PO_DATE`, `AMOUNT`, `STATUS`, `APPROVAL_LEVEL` |
| Buyers | `BUYERS`: `BUYER_NAME`, `HOME_CENTRE_ID` |
