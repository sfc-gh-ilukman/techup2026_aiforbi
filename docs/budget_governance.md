# Budget Governance Standard

| | |
|---|---|
| **Document ID** | PF-FIN-STD-006 |
| **Owner** | Financial Controller |
| **Version** | 1.4 |
| **Effective date** | 1 July 2025 |
| **Review cycle** | Annual |
| **Applies to** | Finance, Centre Managers, Regional Directors |

## 1. Purpose

This standard defines how PeakFit measures performance against budget and when an overspend must be escalated.

## 2. Budgets

1. Budgets are set annually for each centre and general ledger (GL) account, and approved in mid-June before the financial year starts.
2. The financial year runs **1 July to 30 June** (FY2026 = 1 July 2025 to 30 June 2026).
3. **Actual spend** is the value of **Approved** purchase orders charged to the centre and GL account in the financial year.

## 3. Variance

- **Variance = budget − actual spend.**
- A **negative** variance means the line is **overspent**; a positive variance means it is underspent.
- Variance % = variance ÷ budget.

## 4. Budget status bands

| Status | Actual spend as a share of budget |
|---|---|
| Over Budget | More than 110% |
| Slightly Over | More than 100%, up to 110% |
| On Track | 90% to 100% |
| Under Budget | Less than 90% |

## 5. Material overrun

A budget line has a **material overrun** when its actual spend exceeds budget by **more than 10% of the budget and by more than $50,000**. **Both conditions must be met.**

- A line that is 25% over but only $20,000 over is **not** a material overrun (report it as Over Budget only).
- A line that is $80,000 over but only 6% over is **not** a material overrun.

Material overruns must be explained to the CFO by the Regional Director within 15 business days of year-end close.

## 6. In-progress years

Lines in the current, in-progress financial year (FY2027 as at 31 October 2026) are **not** assessed for material overrun until the year closes. Year-to-date monitoring uses straight-line phasing of the annual budget.

## 7. Reporting notes (for analysts)

| Item | Source |
|---|---|
| Budget vs actual | `ANALYTICS.BUDGET_ACTUALS_VW`: one row per centre × GL account × FY, with `BUDGET_AMOUNT`, `ACTUAL_SPEND`, `VARIANCE`, `BUDGET_STATUS` |
