# PeakFit Australia — Data Model for TechUp AI for BI Session (v2)

**Database:** `<PREFIX>_SENSE_DEMO` (default `PEAKFIT_SENSE_DEMO`), built synthetically and deterministically by `sql/01`–`05`
**Domain:** PeakFit Australia — a chain of 23 fitness centres across 6 Australian states
**Date range:** July 2022 – October 2026 (52 months, FY2023–FY2027)
**As-at date:** **2026-10-31** (the presentation date). All "current", "active" and "next N days" logic is evaluated against this date.
**Financial year:** July–June. FY2026 = Jul 2025 – Jun 2026 (the last complete FY). FY2027 is partial (Jul–Oct 2026).
**Relationships:** described in this document, table/column comments and semantic view relationships only. **No PK/FK constraints are declared.**

> Row counts below are what the generator produces (deterministic, identical in every account). Generation and validation run in a separate build database `<PREFIX>_SENSE_BUILD`, then the tables are cloned into `<PREFIX>_SENSE_DEMO` and the build database is dropped, so generation and answer SQL never appear in the demo database's query history.

---

## Architecture Overview

```
<PREFIX>_SENSE_DEMO
├── PUBLIC        15 base tables
├── ANALYTICS     BUDGET_ACTUALS_VW, 2 semantic views, Cortex Agents
├── RAW           stage DOCS — 5 business process documents (MD)
├── APPS          stage + Streamlit app (stage-backed)
└── CORTEX_SENSE  Cortex Sense context home + SENSE_SOURCES stage (query library)
Warehouse: <PREFIX>_SENSE_WH (XS, auto-suspend 60s)
```

| Domain | Tables | Curated? | Purpose in Demo |
|--------|--------|----------|-----------------|
| **Procurement** | 7 tables | Yes — SV1 `PROCUREMENT_ANALYST` | Q1, SV agent |
| **Finance** | 1 table + 1 view | Yes — SV2 `FINANCE_WORKFORCE_ANALYST` | Budget variance |
| **Workforce** | 2 tables | Yes — SV2 `FINANCE_WORKFORCE_ANALYST` | Headcount, staff cost, spend per FTE |
| **Ancillary** | 5 tables | **No — deliberately** | The "long tail" Cortex Sense indexes; Q2 lives here |

**Total:** 15 tables + 1 view + 5 process docs + 1 Streamlit app + query history.

---

## Relationship Map

Two hubs: **PROFIT_CENTRES** (location) and **SUPPLIERS**.

```
                          GL_HIERARCHY (self-ref PARENT_GL_ID)
                                │
BUYERS ──┐                      │              ┌── BUDGETS (centre × GL × FY)
(HOME_CENTRE_ID→PC)             │              │      └─► BUDGET_ACTUALS_VW
         ▼                      ▼              │
SPEND_CODES ──► PO_TRANSACTIONS ◄──────── PROFIT_CENTRES ◄── STAFF_ROSTER (centre × role × month)
                 │    ▲    │                   ▲  ▲  ▲  └── STAFF_COSTS (staff × pay period)
                 │    │    └──► SUPPLIERS ◄────┼──┼──┼──── CONTRACTS
                 ▼    │           ▲  ▲  ▲      │  │  └──── SUPPLIER_ASSESSMENTS (supplier × centre × half-year)
            PO_INVOICES          │  │  └──────┼──┴─────── ASSET_REGISTER (WARRANTY_SUPPLIER_ID, nullable)
                      │          │  │         │
                      └── INCIDENT_LOG (RELATED_PO_ID, RELATED_ASSET_ID, nullable)
                                 │
                      PROCUREMENT_EMAILS (supplier, PO, invoice FKs; THREAD_ID)
```

| From | Column | To | Type |
|------|--------|----|------|
| PO_TRANSACTIONS | BUYER_ID | BUYERS.BUYER_ID | many-to-one |
| PO_TRANSACTIONS | SUPPLIER_ID | SUPPLIERS.SUPPLIER_ID | many-to-one |
| PO_TRANSACTIONS | PROFIT_CENTRE_ID | PROFIT_CENTRES.PROFIT_CENTRE_ID | many-to-one |
| PO_TRANSACTIONS | SPEND_CODE_ID | SPEND_CODES.SPEND_CODE_ID | many-to-one |
| PO_TRANSACTIONS | GL_ACCOUNT_ID | GL_HIERARCHY.GL_ACCOUNT_ID | many-to-one |
| PO_INVOICES | PO_ID | PO_TRANSACTIONS.PO_ID | many-to-one |
| PO_INVOICES | SUPPLIER_ID | SUPPLIERS.SUPPLIER_ID | many-to-one (always equals the PO's supplier) |
| BUYERS | HOME_CENTRE_ID | PROFIT_CENTRES.PROFIT_CENTRE_ID | many-to-one |
| GL_HIERARCHY | PARENT_GL_ID | GL_HIERARCHY.GL_ACCOUNT_ID | self-reference |
| BUDGETS | PROFIT_CENTRE_ID, GL_ACCOUNT_ID | PROFIT_CENTRES, GL_HIERARCHY | many-to-one |
| STAFF_ROSTER / STAFF_COSTS | PROFIT_CENTRE_ID | PROFIT_CENTRES | many-to-one |
| CONTRACTS | SUPPLIER_ID | SUPPLIERS | many-to-one |
| SUPPLIER_ASSESSMENTS | SUPPLIER_ID, PROFIT_CENTRE_ID | SUPPLIERS, PROFIT_CENTRES | many-to-one |
| ASSET_REGISTER | PROFIT_CENTRE_ID | PROFIT_CENTRES | many-to-one |
| ASSET_REGISTER | WARRANTY_SUPPLIER_ID | SUPPLIERS | many-to-one, nullable (~30%) |
| INCIDENT_LOG | PROFIT_CENTRE_ID | PROFIT_CENTRES | many-to-one |
| INCIDENT_LOG | RELATED_PO_ID | PO_TRANSACTIONS | many-to-one, nullable (~25%) |
| INCIDENT_LOG | RELATED_ASSET_ID | ASSET_REGISTER | many-to-one, nullable (~40%) |
| PROCUREMENT_EMAILS | RELATED_SUPPLIER_ID / RELATED_PO_ID / RELATED_INVOICE_ID | SUPPLIERS / PO_TRANSACTIONS / PO_INVOICES | many-to-one, nullable |

**Soft joins (deliberate long-tail traits, no ID column):**
- Email sender → buyer: `PROCUREMENT_EMAILS.SENDER_EMAIL = BUYERS.EMAIL`
- Supplier coverage → centre: `ARRAY_CONTAINS(PROFIT_CENTRES.STATE::VARIANT, SUPPLIERS.SERVICE_REGIONS)`
- Incident → supplier: indirect, via `RELATED_PO_ID → PO_TRANSACTIONS.SUPPLIER_ID`

---

## Domain 1: Procurement (curated)

### PO_TRANSACTIONS (190,826 rows) — Fact table
Grain: one row per purchase order (header level, no line items).

| Column | Type | Notes |
|--------|------|-------|
| PO_ID | VARCHAR | PK |
| PO_NUMBER | VARCHAR | Human-readable reference |
| PO_DATE | DATE | Jul 2022 – Oct 2026 |
| FINANCIAL_YEAR | VARCHAR | FY2023–FY2027 (Jul–Jun) |
| BUYER_ID | VARCHAR | FK → BUYERS |
| SUPPLIER_ID | VARCHAR | FK → SUPPLIERS |
| PROFIT_CENTRE_ID | VARCHAR | FK → PROFIT_CENTRES |
| SPEND_CODE_ID | VARCHAR | FK → SPEND_CODES |
| GL_ACCOUNT_ID | VARCHAR | FK → GL_HIERARCHY |
| DESCRIPTION | VARCHAR | **New in v2.** Generated from spend code + supplier (e.g. "Monthly deep clean – Bondi") |
| AMOUNT | NUMBER(12,2) | PO value in AUD |
| STATUS | VARCHAR | Approved / Pending / Rejected |
| APPROVAL_LEVEL | VARCHAR | Self / Manager / Executive / LT Panel (driven by AMOUNT thresholds in the approval policy doc) |

No split-PO flag columns. PO splitting is planted as a *behaviour* in the data and is only detectable through the policy definition (see Planted Scenarios).

### PO_INVOICES (505,636 rows) — Fact table
Grain: one row per invoice; ~2.75 invoices per approved PO (POs raised in the last weeks before the as-at date may not be invoiced yet).

| Column | Type | Notes |
|--------|------|-------|
| INVOICE_ID | VARCHAR | PK |
| PO_ID | VARCHAR | FK → PO_TRANSACTIONS (Approved POs only) |
| SUPPLIER_ID | VARCHAR | FK → SUPPLIERS (always the PO's supplier) |
| INVOICE_DATE | DATE | ≥ PO_DATE |
| DUE_DATE | DATE | |
| INVOICE_AMOUNT | NUMBER(12,2) | AUD |
| PAYMENT_STATUS | VARCHAR | Paid / Pending / Overdue / On Hold. Overdue = unpaid and DUE_DATE < as-at date |
| DESCRIPTION | VARCHAR | Service description |

### Dimension Tables

| Table | Rows | PK | Key Columns |
|-------|------|----|-------------|
| SUPPLIERS | 50 | SUPPLIER_ID | SUPPLIER_NAME, CATEGORY (14 categories), COMPLIANCE_STATUS (Compliant / Under Review / Non-Compliant), ABN, SERVICE_REGIONS (ARRAY of states) |
| BUYERS | 30 | BUYER_ID | BUYER_NAME, **EMAIL (new in v2)**, ROLE_TITLE, HOME_CENTRE_ID |
| PROFIT_CENTRES | 23 | PROFIT_CENTRE_ID | CENTRE_NAME, STATE (NSW/VIC/QLD/SA/WA/ACT), CENTRE_SIZE (large/medium/small), **HAS_POOL (new in v2, BOOLEAN; 15 centres have a pool)** |
| GL_HIERARCHY | 20 | GL_ACCOUNT_ID | GL_ACCOUNT_NAME, GL_CATEGORY (Operations/Technology/Marketing/Admin/Capital), PARENT_GL_ID |
| SPEND_CODES | 126 | SPEND_CODE_ID | SPEND_CODE_NAME — 126 codes roll up to 20 names (natural duplication, e.g. several "Cleaning Services" codes) |

**Two category taxonomies:** `SUPPLIERS.CATEGORY` (14) and `SPEND_CODES.SPEND_CODE_NAME` (20) are different. "Category spend" means spend grouped by **supplier category**.

---

## Domain 2: Finance (curated)

### BUDGETS (2,300 rows)
Grain: profit centre × GL account × FY (23 × 20 × 5).

| Column | Type | Notes |
|--------|------|-------|
| BUDGET_ID | VARCHAR | PK |
| PROFIT_CENTRE_ID | VARCHAR | FK → PROFIT_CENTRES |
| GL_ACCOUNT_ID | VARCHAR | FK → GL_HIERARCHY |
| GL_CATEGORY | VARCHAR | Denormalised from GL_HIERARCHY |
| FINANCIAL_YEAR | VARCHAR | FY2023–FY2027 |
| BUDGET_AMOUNT | NUMBER(12,2) | AUD, varies by centre size + GL category + year |
| APPROVED_BY | VARCHAR | CFO / COO / Regional Director / Finance Manager |
| APPROVED_DATE | DATE | Typically mid-June before the FY starts |

### BUDGET_ACTUALS_VW (view in ANALYTICS schema)
Joins BUDGETS to approved PO actuals on centre + GL + FY.

| Column | Notes |
|--------|-------|
| ACTUAL_SPEND | SUM of Approved PO amounts matching the budget's centre + GL + FY |
| VARIANCE | BUDGET_AMOUNT − ACTUAL_SPEND (**negative = overspend**) |
| VARIANCE_PCT | VARIANCE / BUDGET_AMOUNT |
| BUDGET_STATUS | Over Budget: actual > 110% of budget · Slightly Over: 100–110% · On Track: 90–100% · Under Budget: < 90% |

---

## Domain 3: Workforce (curated)

### STAFF_ROSTER (9,152 rows)
Grain: profit centre × role type × month. Centres without a pool (`HAS_POOL = FALSE`) have no Pool Lifeguard rows.

| Column | Type | Notes |
|--------|------|-------|
| ROSTER_ID | VARCHAR | PK |
| PROFIT_CENTRE_ID | VARCHAR | FK → PROFIT_CENTRES |
| ROLE_TYPE | VARCHAR | 8 types: Personal Trainer, Group Fitness Instructor, Reception Staff, Cleaning & Maintenance, Centre Manager, Sales Consultant, Pool Lifeguard, Admin & Finance |
| MONTH | DATE | Monthly snapshot (Jul 2022 – Oct 2026) |
| HEADCOUNT | NUMBER | Varies by centre size + season (peaks Jan–Feb, dips Jun–Jul). **Semi-additive: never sum across months** |
| FTE_EQUIVALENT | NUMBER | Adjusted for part-time staff. Semi-additive |

### STAFF_COSTS (69,944 rows)
Grain: one row per staff member per **semi-monthly** pay period.

| Column | Type | Notes |
|--------|------|-------|
| COST_ID | VARCHAR | PK |
| PROFIT_CENTRE_ID | VARCHAR | FK → PROFIT_CENTRES |
| MONTH | DATE | Pay month |
| PAY_PERIOD | NUMBER | 1 = 1st–15th, 2 = 16th–end of month |
| STAFF_ID | VARCHAR | Individual staff identifier (no staff dimension table) |
| ROLE_TYPE | VARCHAR | Same 8 types as STAFF_ROSTER |
| HOURS_WORKED | NUMBER | 30–88 hours per pay period |
| HOURLY_RATE | NUMBER | Varies by role and year (~$24–$86/hr, ~3% annual increases) |
| TOTAL_COST | NUMBER | HOURS_WORKED × HOURLY_RATE |

---

## Ancillary Tables (deliberately uncurated)

These tables are in **no semantic view**. They are the "long tail" Cortex Sense indexes. Q2 depends on them.

### CONTRACTS (2,696 rows)

| Column | Type | Notes |
|--------|------|-------|
| CONTRACT_ID | VARCHAR | PK |
| SUPPLIER_ID | VARCHAR | FK → SUPPLIERS |
| CONTRACT_TYPE | VARCHAR | 10 types (MSA, SOW, Framework Agreement, etc.) |
| START_DATE / END_DATE | DATE | Contract period |
| CONTRACT_VALUE | NUMBER | AUD |
| CONTRACT_STATUS | VARCHAR | Active / Expired / Under Renewal. Consistent with dates vs the as-at date (no Active contract has END_DATE < 2026-10-31) |
| RENEWAL_TYPE | VARCHAR | Annual / Biennial / Auto-renew / Fixed Term |

### SUPPLIER_ASSESSMENTS (5,831 rows)
Grain: supplier × profit centre × half-year. A centre assesses a supplier for a half-year when it raised at least 8 approved POs with that supplier in the period (so only in states the supplier services).

| Column | Type | Notes |
|--------|------|-------|
| ASSESSMENT_ID | VARCHAR | PK |
| SUPPLIER_ID / PROFIT_CENTRE_ID | VARCHAR | FKs |
| ASSESSMENT_PERIOD | VARCHAR | **H1-FY2023 through H2-FY2026** (8 completed periods; H1-FY2027 is still in progress as at 2026-10-31). H1 = Jul–Dec, H2 = Jan–Jun. **Sorting this string alphabetically gives the wrong order** — order by FY, then half |
| QUALITY_SCORE / TIMELINESS_SCORE / COMMUNICATION_SCORE / VALUE_FOR_MONEY_SCORE | NUMBER(3,2) | **1.00–5.00** |
| OVERALL_SCORE | NUMBER(3,2) | Mean of the 4 scores |
| RECOMMENDATION | VARCHAR | Preferred / Approved / Conditional / Not Recommended |
| ASSESSOR_COMMENTS | VARCHAR | Free text |

### ASSET_REGISTER (15,703 rows)

| Column | Type | Notes |
|--------|------|-------|
| ASSET_ID | VARCHAR | PK |
| PROFIT_CENTRE_ID | VARCHAR | FK → PROFIT_CENTRES |
| ASSET_CATEGORY | VARCHAR | 12 categories (Cardio, Strength, Pool, HVAC, IT, Fitout, etc.). Pool assets only at `HAS_POOL` centres |
| PURCHASE_COST | NUMBER | AUD |
| ASSET_STATUS | VARCHAR | Active / Needs Maintenance / Decommissioned / Disposed |
| WARRANTY_SUPPLIER_ID | VARCHAR | FK → SUPPLIERS (nullable, ~35% have a warranty) |

### INCIDENT_LOG (58,609 rows)

| Column | Type | Notes |
|--------|------|-------|
| INCIDENT_ID | VARCHAR | PK |
| PROFIT_CENTRE_ID | VARCHAR | FK → PROFIT_CENTRES (equals the related PO's centre when linked) |
| INCIDENT_DATE | DATE | Jul 2022 – Oct 2026 |
| INCIDENT_TYPE | VARCHAR | 20 types across 5 categories |
| INCIDENT_CATEGORY | VARCHAR | Maintenance / OH&S / Customer / Security / IT |
| SEVERITY | VARCHAR | Critical / High / Medium / Low |
| STATUS | VARCHAR | Open / In Progress / Resolved / Closed |
| RELATED_PO_ID | VARCHAR | FK → PO_TRANSACTIONS (nullable, ~22% linked; the PO is with a supplier of the matching type at the same centre, raised in the 90 days before the incident) |
| RELATED_ASSET_ID | VARCHAR | FK → ASSET_REGISTER (nullable, ~39% linked) |

### PROCUREMENT_EMAILS (102,450 rows)
Email metadata (no body text).

| Column | Type | Notes |
|--------|------|-------|
| EMAIL_ID | VARCHAR | PK |
| EMAIL_DATE | DATE | |
| SUBJECT | VARCHAR | Generated from 20 templates with supplier/PO references |
| EMAIL_CATEGORY | VARCHAR | Invoice / Approval / Payment / Procurement / Contract / Compliance / etc. |
| SENDER_NAME / SENDER_EMAIL | VARCHAR | PeakFit buyer (soft join to BUYERS.EMAIL) |
| RECIPIENT_NAME / RECIPIENT_EMAIL | VARCHAR | Supplier or internal |
| RELATED_SUPPLIER_ID | VARCHAR | FK → SUPPLIERS |
| RELATED_PO_ID / RELATED_INVOICE_ID | VARCHAR | Nullable FKs |
| THREAD_ID | NUMBER | Groups emails into ~31K conversation threads (anchored on POs, invoices, contract renewals and compliance follow-ups) |

---

## Data Integrity Rules (enforced in generation)

1. Invoices exist only for **Approved** POs; `PO_INVOICES.SUPPLIER_ID` = the PO's supplier; `INVOICE_DATE >= PO_DATE`.
2. `APPROVAL_LEVEL` matches AMOUNT against the approval policy thresholds (except planted splits, which stay under each threshold individually).
3. `CONTRACT_STATUS` is consistent with START/END dates relative to 2026-10-31.
4. When `RELATED_PO_ID` is set, the incident's centre = the PO's centre.
5. Assessments only exist where the supplier services the centre's state.
6. Pool Lifeguard roster rows and Pool assets only exist at `HAS_POOL` centres.
7. No assessment for an in-progress period (nothing after H2-FY2026).
8. Generation is SQL-native and seeded, so it is reproducible and re-runnable.

---

## Business Rules

These rules are the "tribal knowledge" for the demo. They live in the **process documents** (see Unstructured Data), not in the schema or the semantic views. This file is a design spec and is **not** uploaded to the Cortex Sense stage.

| Rule | Definition | Source doc |
|------|-----------|------------|
| **Spend** | Approved POs only, FY Jul–Jun | SV1 instructions + glossary |
| **Category spend** | Grouped by `SUPPLIERS.CATEGORY` | SV1 instructions + glossary |
| **At-risk supplier** | (a) supplier-level score (average of OVERALL_SCORE across centres) < 3.00 in **each** of the two most recent completed periods (H1-FY2026 and H2-FY2026), **OR** (b) ≥ 3 High/Critical incidents in the last 6 months linked via `RELATED_PO_ID → PO.SUPPLIER_ID`. Asset/warranty-linked incidents do not count | supplier_management_process.md |
| **Expiring soon** | `CONTRACT_STATUS = 'Active'` AND END_DATE within 90 days of the as-at date AND `RENEWAL_TYPE <> 'Auto-renew'`. Under Renewal is not active | contract_renewal_process.md |
| **Approval thresholds** | Self ≤ $5K · Manager ≤ $50K · Executive ≤ $250K · LT Panel > $250K | procurement_approval_policy.md |
| **PO splitting** | Same buyer + same supplier + same spend code, ≥ 2 Approved POs raised within 3 days of each other, each between $4,000 and $5,000 (just under the $5K Self limit), combined over $5,000 | procurement_approval_policy.md |
| **Material overrun** | Overspend > 10% of budget **and** > $50K (both conditions) | budget_governance.md |
| **Tail spend** | Suppliers outside the top 80% of cumulative approved spend | glossary.md |
| **Supplier Risk Score** | 0–100 = 40% × (5 − avg overall score)/4 + 30% × overdue invoice ratio + 30% × min(High/Critical incidents in 12 months / 5, 1) | Streamlit app code only |

---

## Planted Scenarios

### Q2 — "Which at-risk suppliers have active contracts expiring in the next 90 days, and what's their FY2026 spend?"
Window: END_DATE between 2026-10-31 and 2027-01-29.

| Scenario | Suppliers | Purpose |
|----------|-----------|---------|
| At-risk via scores, Active non-auto-renew contract in window | SUP015, SUP026, SUP040 | Golden rows |
| At-risk via incidents (4 PO-linked High/Critical since mid-May), contract in window | SUP014 | Golden row, exercises rule (b) |
| Low in H2-FY2025 + H2-FY2026, fine in H1-FY2026 | SUP032 | Decoy: alphabetical period sort wrongly flags it |
| RECOMMENDATION = 'Not Recommended' (commercial grounds) but scores ≥ 3.00 | SUP022 | Decoy: guessing from the column name |
| At-risk, contract in window is Auto-renew | SUP050 | Decoy: ignoring the exclusion |
| At-risk, contract ends 2027-02-14 (day 106) | SUP008 | Decoy: window edge |
| At-risk, contract in window is Under Renewal | SUP030 | Decoy: status rule |
| Low in H2-FY2026 only | SUP037 | Decoy: "each of the two periods" |
| 5 High/Critical incidents linked only via assets under its warranty | SUP034 | Decoy: warranty-linked incidents don't count |

No supplier other than SUP014 has more than 2 PO-linked High/Critical incidents since 2026-04-01, and no unplanted supplier averages below 3.00 in any period.

**Golden answer** (computed by `sql/06_validation.sql`, as at 2026-10-31):

| Supplier | Category | Why at risk | Next expiry | FY2026 approved spend |
|----------|----------|-------------|-------------|-----------------------|
| SUP014 GymCare Technical Services | Equipment Servicing | 4 High/Critical incidents in last 6 months | 2026-12-13 | $1,847,517.47 |
| SUP040 CoolBreeze HVAC Solutions | HVAC Services | Scores 2.88 / 2.59 | 2026-12-22 | $1,438,407.17 |
| SUP015 Precision Equipment Servicing | Equipment Servicing | Scores 2.79 / 2.64 | 2026-12-14 | $1,117,802.23 |
| SUP026 Local Pulse Media | Marketing & Advertising | Scores 2.71 / 2.85 | 2027-01-12 | $1,117,194.08 |

**Total: $5,520,920.95**

### Other planted patterns
- **PO splitting:** buyers BUY008, BUY012, BUY020, BUY026 — 51 clusters / 117 POs (Jul 2024 – Oct 2026). In FY2026 these 4 buyers have 44 qualifying pairs vs 14 across the other 26 buyers.
- **Material overrun (FY2026):** exactly 4 centre × GL lines (one each in NSW, VIC, QLD, WA). Decoys from natural data: 11 lines over by > 10% but < $50K, 16 lines over by > $50K but < 10%.

---

## Semantic Views (curated layer)

### SV1: `ANALYTICS.PROCUREMENT_ANALYST`
- **Tables:** PO_TRANSACTIONS, PO_INVOICES, SUPPLIERS, BUYERS, PROFIT_CENTRES, GL_HIERARCHY, SPEND_CODES (7 relationships)
- **Metrics:** TOTAL_SPEND (Approved), PO_COUNT, AVERAGE_PO_VALUE, TOTAL_INVOICED, INVOICE_COUNT, OVERDUE_AMOUNT
- **Custom instructions:** FY runs Jul–Jun; "spend" means Approved POs only; default to FY2026; category spend via SUPPLIERS.CATEGORY
- **Verified queries:** overdue invoices by state, supplier invoices, total approved spend, approval level distribution, **plus Q1: approved FY2026 spend by state**
- **No Cortex Search services** (sample values cover 50 suppliers / 23 centres)

### SV2: `ANALYTICS.FINANCE_WORKFORCE_ANALYST` (new)
- **Tables:** BUDGETS, BUDGET_ACTUALS_VW, STAFF_ROSTER, STAFF_COSTS, PROFIT_CENTRES, GL_HIERARCHY
- **Metrics:** TOTAL_BUDGET, ACTUAL_SPEND, VARIANCE, VARIANCE_PCT, HEADCOUNT / FTE (latest month or monthly average, never summed across months), TOTAL_STAFF_COST, SPEND_PER_FTE
- **Verified queries:** budget status by state, staff cost by role, spend per FTE by centre size

**Hard rule:** CONTRACTS, SUPPLIER_ASSESSMENTS, INCIDENT_LOG, ASSET_REGISTER and PROCUREMENT_EMAILS are in **neither** SV, and no policy Cortex Search service is attached to the SV agent. Only the Cortex Sense agent can answer Q2.

---

## Unstructured Data — Process Documents (`@RAW.DOCS`)

Written as realistic internal documents (owner, version, effective date), not answer sheets.

| Document | Carries |
|----------|---------|
| `supplier_management_process.md` | Assessment cycle, at-risk definition, centre roll-up, period ordering (FY first, then half), incident attribution, escalation |
| `contract_renewal_process.md` | Expiring-soon window, Auto-renew exclusion, Under Renewal ≠ Active, owners by contract type |
| `procurement_approval_policy.md` | Approval thresholds, PO splitting definition, exceptions |
| `budget_governance.md` | Variance sign convention, BUDGET_STATUS bands, material overrun |
| `glossary.md` | vendor = supplier, cost centre = profit centre, category spend, tail spend, maverick spend |

---

## Streamlit App — "PeakFit Procurement Insights" (`@APPS`, stage-backed)

- **Pages:** Spend overview (state / category / FY), Budget vs actual, Supplier Scorecard
- **Supplier Risk Score** formula exists **only in the app code**
- Source is uploaded to `@APPS.STREAMLIT_SRC` and the app is created from that stage (warehouse runtime), so the Cortex Sense build can read it

---

## Query History

- Generated by `sql/13`–`15` as your own user (`distinct_users = 1`). Each persona block sets a JSON `QUERY_TAG` (procurement analyst, supplier manager, contracts manager, finance analyst, facilities manager, procurement ops).
- 27 parameterised analyst query templates; batches 2 and 3 re-run the hot templates with different parameters. Re-running them on later days gives a richer history but isn't required.
- Templates provide **building blocks, not the answer**: supplier score roll-up with correct period ordering, incident → PO → supplier attribution, contracts by end date, approved spend by FY, budget variance, spend per FTE, split-PO candidate detection. No single query computes Q2 end-to-end.
- **Seeded query-pattern library:** `docs/analyst_query_library.md` (PF-ANA-QL-001) on `@CORTEX_SENSE.SENSE_SOURCES`. 29 reviewed SQL patterns (QL-01 to QL-29), each with business question, persona, run frequency and caveats. It's indexed as a stage file, so it works even when the role can't read `ACCOUNT_USAGE`. Same building-block rule: QL-13 (rule a), QL-14 (rule b) and QL-19 (expiring + FY spend) are separate, with no at-risk × expiring join. Present it as *seeded* in the talk track.
- `ACCOUNT_USAGE.QUERY_HISTORY` lags 45 minutes to a few hours, which is why setup is split into phase A (data + workload) and phase B (Sense context).

---

## Cortex Sense, Eval and Agents

- **Context:** `PROCUREMENT` in `<PREFIX>_SENSE_DEMO.CORTEX_SENSE`. Scope: `PUBLIC.*`, `ANALYTICS.*`, both SVs, the Streamlit app, the 5 process docs and the query library as stage files, plus mined query history.
- **Eval:** 12 answer-tier + 3 retrieval-tier questions in `eval/eval.yaml`, pinned "as at 2026-10-31", goldens computed with SQL. Baseline vs context; `answer_lift` is the headline.
- **Agents (`ANALYTICS`):**

| Agent | Tools | Q1 | Q2 |
|-------|-------|----|----|
| `PEAKFIT_NAKED_AGENT` | none | fails | fails |
| `PEAKFIT_SV_AGENT` | SV1 + SV2 (Cortex Analyst) | answers | fails |
| `PEAKFIT_SENSE_AGENT` | `EnableCortexSense` + `data_to_chart` | answers (same number as SV) | answers |
| `PEAKFIT_SV_SENSE_AGENT` | SV1 + SV2 + Sense (`AgenticAnalystAllowArbitrarySQL`) | answers | answers |

**Business Ontology:** domain `<PREFIX>_PROCUREMENT`, built by `sql/40_ontology.sql` or by Cortex Code (see `labs/04-business-ontology.md`).

---

## Access

- Role from `config/lab.config.yaml` (default `SYSADMIN`) owns every object.
- Optional: `GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE <role>` so Cortex Sense can mine query history.
- **Warehouse:** `<PREFIX>_SENSE_WH` (XS, auto-suspend 60s)
