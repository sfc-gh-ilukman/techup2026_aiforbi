# Contract Renewal Process

| | |
|---|---|
| **Document ID** | PF-PROC-CRP-002 |
| **Owner** | Contracts Manager, Procurement |
| **Version** | 2.3 |
| **Effective date** | 1 March 2025 |
| **Review cycle** | Annual |
| **Applies to** | Procurement, Category Managers, Legal |

## 1. Purpose

This process makes sure supplier contracts are reviewed before they lapse, so that renewal decisions are taken deliberately rather than by default.

## 2. Contract statuses

| Status | Meaning |
|---|---|
| **Active** | The contract term is current. |
| **Under Renewal** | Negotiation of the next term has formally started and the contract is on the renewal tracker. |
| **Expired** | The term has ended. |

## 3. Expiring soon

A contract is **expiring soon** when **all** of the following are true at the review date:

1. Its status is **Active**.
2. Its end date falls **within the next 90 days** (the review date up to and including review date + 90 days).
3. Its renewal type is **not Auto-renew**.

**Auto-renew** contracts roll over automatically unless notice is given, so they are managed through the notice register and are excluded from the expiring-soon list. **Under Renewal** contracts are already in negotiation and are tracked on the renewal tracker, so they are also excluded.

As at 31 October 2026, the expiring-soon window is 31 October 2026 to 29 January 2027.

## 4. Renewal timeline

| Days before end date | Action | Owner |
|---|---|---|
| 120 | Contract appears on the renewal forecast | Contracts Manager |
| 90 | Contract becomes **expiring soon**; renewal decision required | Category Manager |
| 60 | Go-to-market or renegotiation started; status moves to Under Renewal | Category Manager |
| 30 | Legal review of new terms | Legal |

## 5. Owners by contract type

| Contract type | Owner |
|---|---|
| Master Services Agreement, Framework Agreement | Head of Procurement |
| Service Level Agreement, Maintenance Agreement, Statement of Work | Category Manager |
| Supply Agreement, Purchase Agreement, Lease Agreement | Category Manager |
| Licence Agreement | IT Procurement Lead |
| Consultancy Agreement | Head of Procurement |

## 6. At-Risk Renewal Watchlist

Each month Procurement publishes the **At-Risk Renewal Watchlist** to the Executive team. It lists every supplier that:

1. Is **at risk** under the Supplier Management Process (PF-PROC-SMP-004, Section 4), **and**
2. Has at least one contract that is **expiring soon** (Section 3 above).

For each supplier the watchlist shows the reason it is at risk, the next expiring contract end date, and the supplier's **approved spend for the latest complete financial year** (Approved purchase orders only; FY = July to June).

Renewing a contract for a supplier on the watchlist requires Head of Procurement sign-off and a remediation plan.

## 7. Reporting notes (for analysts)

| Item | Source |
|---|---|
| Contracts | Contract register (`CONTRACTS`): `CONTRACT_STATUS`, `END_DATE`, `RENEWAL_TYPE`, `SUPPLIER_ID` |
| Approved spend | Purchase orders (`PO_TRANSACTIONS`) with `STATUS = 'Approved'`, by `FINANCIAL_YEAR` |
