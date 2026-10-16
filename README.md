# PeakFit: Cortex Sense + Business Ontology lab

A complete, self-contained demo of **Cortex Sense** and **Business Ontology** for Snowflake Solution Engineers. Clone it, open it in Cortex Code, say *"set up the PeakFit lab"*, and you have the same demo used in the regional *AI for BI* session running in your own account.

> A semantic view answers the questions you *curated for*. Cortex Sense answers the questions your business *actually asks*, because it indexes everything around the curated layer: uncurated tables, process docs, query history and the apps people already use. Business Ontology is where stewards make that meaning official.

**The dataset:** PeakFit Australia, a fictional chain of 23 fitness centres across 6 states, FY2023–FY2027. It includes procurement, finance, workforce and an uncurated "long tail", generated deterministically, so every expected answer in this repo matches your account to the cent.

---

## Prerequisites

| | Requirement |
|---|---|
| **Account** | A Snowflake demo account with **Cortex Sense** and **Business Ontology** enabled (`python3 scripts/lab.py preflight` checks both) |
| **Role** | A role with `CREATE DATABASE` and `CREATE WAREHOUSE` (SYSADMIN or ACCOUNTADMIN). Optional but recommended: `GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE <role>`, so Sense can mine query history |
| **Tools** | [Cortex Code](https://docs.snowflake.com/en/user-guide/cortex-code/cortex-code) (desktop or CLI), the [Snowflake CLI](https://docs.snowflake.com/developer-guide/snowflake-cli/installation/installation) (`snow`) with a working connection, and Python 3.9+ (standard library only) |
| **Cost** | One XS warehouse (auto-suspend 60s). Setup takes about 10–20 minutes of XS compute, plus the Cortex Sense build and any agent or eval runs |

## Quickstart

```bash
git clone https://github.com/sfc-gh-ilukman/peakfit-cortex-sense-lab.git
cd peakfit-cortex-sense-lab
coco .        # or open the folder in Cortex Code Desktop / run `cortex` here
```

Then, in the Cortex Code chat:

```
set up the PeakFit lab
```

The repo ships a project skill ([`.snowflake/cortex/skills/peakfit-lab`](.snowflake/cortex/skills/peakfit-lab/SKILL.md)) that Cortex Code picks up automatically. It:

1. asks for your **connection, role and a name prefix** (default `PEAKFIT`, so several people can share one account),
2. runs a **preflight** (connection, Cortex Sense, Business Ontology, ACCOUNT_USAGE access),
3. deploys **phase A** step by step, checking the golden answers before anything is promoted,
4. tells you when to come back for **phase B**: *"continue the PeakFit lab"*.

<details>
<summary>Prefer a terminal? Same steps, no Cortex Code needed.</summary>

```bash
python3 scripts/lab.py init --connection <your_snow_connection> --role SYSADMIN --prefix PEAKFIT
python3 scripts/lab.py preflight
python3 scripts/lab.py deploy        # phase A, ~10-20 min
python3 scripts/lab.py history       # wait until the workload shows in ACCOUNT_USAGE
python3 scripts/lab.py sense         # phase B: create the Cortex Sense context
python3 scripts/lab.py status
```
</details>

### Why two phases?

Cortex Sense mines **query history** from `SNOWFLAKE.ACCOUNT_USAGE`, which lags 45 minutes to a few hours. Phase A runs a realistic analyst workload. Phase B creates the context once that history is visible. The Sense build itself is also asynchronous (minutes to hours), so **set the lab up the day before you present**.

While you wait, [lab 04 (Business Ontology)](labs/04-business-ontology.md) is ready to go as soon as phase A finishes.

---

## What gets built

```
<PREFIX>_SENSE_DEMO
├── PUBLIC        15 tables: 10 curated (procurement, finance, workforce) + 5 uncurated
│                 (CONTRACTS, SUPPLIER_ASSESSMENTS, INCIDENT_LOG, ASSET_REGISTER, PROCUREMENT_EMAILS)
├── ANALYTICS     BUDGET_ACTUALS_VW · semantic views PROCUREMENT_ANALYST, FINANCE_WORKFORCE_ANALYST
│                 · agents PEAKFIT_NAKED / _SV / _SENSE / _SV_SENSE
├── RAW           @DOCS: 5 business process documents (the rules no schema contains)
├── APPS          PeakFit Procurement Insights Streamlit app (Supplier Risk Score lives only here)
└── CORTEX_SENSE  Cortex Sense context PROCUREMENT · @SENSE_SOURCES: analyst query library
<PREFIX>_SENSE_WH   XS warehouse
<PREFIX>_PROCUREMENT  Business Ontology domain: 24 nodes, 30 typed relationships, 28 representations
```

The curated semantic views deliberately **exclude** the five uncurated tables, and the business definitions live only in the docs. That gap is what makes the demo work: no change to a semantic view should ever let the semantic view agent answer Q2.

## The labs

| Lab | What you show | Time |
|---|---|---|
| [01 · Cortex Sense in Cortex Code](labs/01-cortex-sense.md) | Discovery, the hero question, an app-only metric, tracing answers to sources | 25–30 min |
| [02 · The agent ladder](labs/02-agent-ladder.md) | No tools → semantic views → Cortex Sense on two questions, with expected answers and decoys | 15–20 min |
| [03 · Eval](labs/03-eval.md) | Baseline vs context, `answer_lift`, per-question deltas | 15 min + unattended run |
| [04 · Business Ontology](labs/04-business-ontology.md) | Tour the governed domain, build it yourself with Cortex Code, consume it, and how it relates to Sense | 30–45 min |

### The two hero questions

| | Question | Answer |
|---|---|---|
| **Q1** (curated) | What was total approved spend in FY2026 by state? | VIC 50.57M, NSW 47.49M, QLD 38.56M, WA 24.58M, SA 21.03M, ACT 6.39M = **$188,621,151.95** |
| **Q2** (context gap) | Which at-risk suppliers have active contracts expiring in the next 90 days, and what's their FY2026 spend? | SUP014, SUP040, SUP015, SUP026 = **$5,520,920.95** |

Agents don't always apply every exclusion on Q2 (Auto-renew, Under Renewal). For an exact on-stage answer, use the strict-watchlist wording in [lab 02](labs/02-agent-ladder.md#if-the-sense-agent-misses-q2), and use the miss itself as the bridge to the eval.

---

## Repo layout

| Path | What |
|---|---|
| `scripts/lab.py` | The driver: `init`, `preflight`, `deploy`, `history`, `sense`, `status`, `ask`, `teardown`. Run with `-h` |
| `config/lab.config.example.yaml` | Connection, role, prefix (copied to `config/lab.config.yaml`, gitignored) |
| `sql/` | Numbered setup steps, templated with `{{DB}}`, `{{WH}}`, `{{ROLE}}` … |
| `docs/` | The business process documents and query library that Sense indexes |
| `apps/peakfit_procurement_insights/` | The Streamlit app |
| `sense/scope.yaml` | The Cortex Sense scope manifest |
| `eval/eval.yaml` | 15 eval questions with SQL-computed goldens |
| `ontology/peakfit_ontology.json` | The Business Ontology spec (nodes, relationships, representations) |
| `reference/DATA_MODEL.md` | Full data model, business rules and planted scenarios |
| `.build/` | Rendered copies for your prefix, plus logs (gitignored, regenerated on every run) |

## Re-running and resetting

- Any step can be re-run: `python3 scripts/lab.py run 30_agents` (agents) or `run 40_ontology` (resets the ontology domain to the spec).
- Resume a failed deploy: `python3 scripts/lab.py deploy --from <step>`.
- **Remove everything** (database, warehouse, ontology domain, Sense context): say *"tear down the PeakFit lab"* in Cortex Code, or run `python3 scripts/lab.py teardown --yes`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Preflight `FAIL` on Cortex Sense or Business Ontology | The feature isn't enabled on the account. Ask the account admin; the lab can't work around it |
| Preflight `WARN` on ACCOUNT_USAGE | `GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE <role>` (as ACCOUNTADMIN). Without it, Sense skips query-history mining. The seeded query library still gives it SQL patterns |
| `06b_gate` FAIL | The generated data doesn't match the goldens. Re-run `python3 scripts/lab.py deploy` from scratch and report the `.build/logs/06b_gate.log` if it persists |
| A step fails | Read `.build/logs/<step>.log`, fix, then run `python3 scripts/lab.py deploy --from <step>` |
| Agents fail to create, or answer with a model error | Cortex Agents need Cortex AI models in your region; enable cross-region inference (`ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION'`, ACCOUNTADMIN) |
| Sense agent misses Q2 | The context build probably hasn't finished. Check with `$cortex-sense resume PROCUREMENT check build` |
| Streamlit app shows an error | Open it in Snowsight (`<DB>.APPS.PEAKFIT_PROCUREMENT_INSIGHTS`). It runs on the warehouse runtime and needs `streamlit=1.52.2` from the Snowflake channel |

## What's honest to say on stage

- Cortex Sense **extracts its own definitions** (`ontology_node` documents) from docs, apps and semantic views during the build. It doesn't read Business Ontology today; a `business_ontology` scope source exists but isn't indexed yet.
- This repo hasn't verified that Cortex Agents read Business Ontology at runtime. Cortex Code does, through the business-ontology skill.
- The query library on `@SENSE_SOURCES` is **seeded** analyst SQL; present it as such.
- The Sense build has no "done" state yet. Build ahead of time and never build live.

---

*Synthetic data. PeakFit Australia is fictional. Not an official Snowflake product or support channel.*
