# Lab 01 · Cortex Sense in Cortex Code

**Time:** 25–30 min · **Needs:** phase B done (`python3 scripts/lab.py sense`) and the build finished

> A semantic view answers the questions you *curated for*. Cortex Sense answers the questions your business *actually asks*, because it indexes everything around the curated layer: uncurated tables, process docs, query history and the apps people already use.

`<DB>` is your demo database (default `PEAKFIT_SENSE_DEMO`). The context is `<DB>.CORTEX_SENSE.PROCUREMENT`.

## What the context indexes

| Source | In this lab | Why it matters |
|---|---|---|
| Catalog metadata | `<DB>.PUBLIC.*` (15 tables), `<DB>.ANALYTICS.*` | Includes 5 **uncurated** tables that no semantic view covers: CONTRACTS, SUPPLIER_ASSESSMENTS, INCIDENT_LOG, ASSET_REGISTER, PROCUREMENT_EMAILS |
| Semantic views | `PROCUREMENT_ANALYST`, `FINANCE_WORKFORCE_ANALYST` | The curated layer and its verified queries |
| Stage files | 5 process docs on `@RAW.DOCS`, query library on `@CORTEX_SENSE.SENSE_SOURCES` | Business rules that exist nowhere in the schema |
| Streamlit app | `@APPS.STREAMLIT_SRC` | The Supplier Risk Score formula exists **only** in app code |
| Query history | Mined from `ACCOUNT_USAGE` (if the role can read it) | Real SQL patterns from analyst personas |

The manifest is in [`sense/scope.yaml`](../sense/scope.yaml), and the rendered copy is in `.build/sense/scope.yaml`.

---

## 1. Discovery: how a builder starts (2 min, nothing saved)

In a new Cortex Code chat:

```
set up cortex sense for procurement on <DB>
```

Cortex Code scans the account in seconds and proposes a scope: tables, the two semantic views, the Streamlit app, the docs on stage, and hot tables from usage. Walk through each source row. The builder **steers** in plain English (*"exclude PROCUREMENT_EMAILS"*, *"add the query library on @CORTEX_SENSE.SENSE_SOURCES"*) instead of writing YAML.

**Stop before saving.** Say *cancel*. The lab's context already exists, and the build runs offline.

## 2. Ask the hero question in Cortex Code

```
/cortex-sense query PROCUREMENT about: Which at-risk suppliers have active
contracts expiring in the next 90 days, and what's their FY2026 spend?
```

Expected: SUP014, SUP040, SUP015 and SUP026, totalling **$5,520,920.95** (full table in [lab 02](02-agent-ladder.md)).

Show the documents that come back, grouped by `doc_type`:

| `doc_type` | What you'll see |
|---|---|
| `ontology_node` | *At-Risk Classification* (both rules), *Expiring-Soon Contract*, *Supplier*, with rules that cite their source file (`supplier_management_process.md`, `contract_renewal_process.md`) |
| `table_entity` | CONTRACTS, SUPPLIER_ASSESSMENTS, INCIDENT_LOG: grain, columns, joins |
| `qbe` | Reviewed SQL patterns and verified queries (e.g. FY2026 approved spend) |

End on the citation line Cortex Code prints (`⎿ N citations from Cortex Sense`).

## 3. A metric that lives only in an app

```
/cortex-sense how is the Supplier Risk Score on the procurement scorecard
calculated, and which five suppliers score highest right now?
```

Expected:

```
Risk = 100 × ( 0.40 × (5 − avg_overall_score) / 4
             + 0.30 × overdue_invoice_value / invoiced_value
             + 0.30 × MIN(serious_incidents / 5, 1) )
```

The score uses the last two completed half-years, a 12-month window to 31 Oct 2026, High/Critical PO-linked incidents only, and a neutral 3.00 when there are no assessments. Bands: High ≥ 40, Elevated ≥ 25.

| # | Supplier | Risk score |
|---|---|---|
| 1 | SUP014 GymCare Technical Services | 44.3 |
| 2 | SUP013 FitTech Service & Repair | 42.6 |
| 3 | SUP001 SparkleClean Commercial | 41.8 |
| 4 | SUP030 Vigilant Alarm Monitoring | 41.6 |
| 5 | SUP005 Apex Facility Services | 37.7 |

**The nuance to land:** Sense also knows that this score is a dashboard indicator and **not** the at-risk definition. SUP013 tops the score but isn't at risk under the policy. A model guessing from names would conflate the two.

## 4. Trace an answer back to its sources

```
/cortex-sense tell me about the context you used to answer this question and
where it came from
```

Cortex Code re-runs the lookup in verbose mode. Each rule carries a `source_locator`:

- The weights come from `@APPS.STREAMLIT_SRC/peakfit_procurement_insights` (the extractor quotes `RISK_WEIGHT_PERFORMANCE = 0.40` and so on).
- The at-risk rules come from `@RAW.DOCS/supplier_management_process.md`.
- The table schemas come from catalog metadata and the semantic view.

This is the governance story: every filter is traceable.

## 5. Correct an answer

When an answer is wrong, the builder doesn't edit YAML:

```
$cortex-sense resume PROCUREMENT
the risk score should exclude suppliers marked Non-Compliant
```

This routes to **refine** (a scope change) or, if you say *record feedback*, to **feedback** (a stored correction that's served back with future lookups). Don't save this example correction, or undo it afterwards.

## 6. Talking points

- **Sense respects the curated layer.** Q1 returns the same number as the semantic view agent ([lab 02](02-agent-ladder.md)).
- **Discovery is automatic.** The builder steers instead of hand-writing YAML.
- **It grounds the coding agent too**, not only end-user agents.
- **The build is offline and asynchronous.** Never build live in a demo; build the day before.
