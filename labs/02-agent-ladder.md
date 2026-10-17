# Lab 02 · The agent ladder

**Time:** 15–20 min · **Needs:** phase B done and the Sense build finished (rung 1 and 2 work right after phase A)

Four agents in `<DB>.ANALYTICS`, each with more context than the last. You ask the same two questions to each. Find them in Snowsight under **AI & ML » Agents**, or in Snowflake CoWork as *PeakFit 1 – No tools* to *PeakFit 4 – Semantic views + Sense*.

| Rung | Agent | Tools |
|---|---|---|
| 1 | `PEAKFIT_NAKED_AGENT` | none |
| 2 | `PEAKFIT_SV_AGENT` | `PROCUREMENT_ANALYST` + `FINANCE_WORKFORCE_ANALYST` semantic views |
| 3 | `PEAKFIT_SENSE_AGENT` | `EnableCortexSense: true` (adds `cortex_sense` + `system_execute_sql`) + `data_to_chart` |
| 4 | `PEAKFIT_SV_SENSE_AGENT` | both semantic views **and** Cortex Sense (`AgenticAnalystAllowArbitrarySQL`) |

The full specs are in [`sql/30_agents.sql`](../sql/30_agents.sql). The Sense agent's spec really is that small: one experimental flag and one declared tool.

You can run every step from a terminal too:

```bash
python3 scripts/lab.py ask naked "What was total approved spend in FY2026 by state?"
python3 scripts/lab.py ask sv    "What was total approved spend in FY2026 by state?"
python3 scripts/lab.py ask sense "What was total approved spend in FY2026 by state?"
```

`ask` prints the tools the agent called (for example `cortex_sense -> system_execute_sql`) and the answer.

---

## Q1, the curated question

> **What was total approved spend in FY2026 by state?**

| State | Approved spend (AUD) |
|---|---|
| VIC | 50,570,553.46 |
| NSW | 47,494,913.78 |
| QLD | 38,557,185.43 |
| WA | 24,581,847.90 |
| SA | 21,026,484.08 |
| ACT | 6,390,167.30 |
| **Total** | **188,621,151.95** |

| Rung | Expected |
|---|---|
| 1 No tools | Can't answer, or invents a number. If it invents one, point that out: confidently wrong is the risk |
| 2 Semantic views | Correct. FY = July–June and "spend" = Approved POs are both in the semantic view. Give it full credit |
| 3 Sense | **The same numbers** as rung 2. Sense respects the curated layer rather than replacing it |
| 4 SV + Sense | Correct, usually through the semantic view |

## Q2, the context-gap question

> **Which at-risk suppliers have active contracts expiring in the next 90 days, and what's their FY2026 spend?**

| Supplier | Why at risk | Next expiry | FY2026 approved spend |
|---|---|---|---|
| SUP014 GymCare Technical Services | 3+ High/Critical PO-linked incidents in 6 months | 2026-12-13 | 1,847,517.47 |
| SUP040 CoolBreeze HVAC Solutions | Below 3.00 in H1 and H2 FY2026 | 2026-12-22 | 1,438,407.17 |
| SUP015 Precision Equipment Servicing | Below 3.00 in H1 and H2 FY2026 | 2026-12-14 | 1,117,802.23 |
| SUP026 Local Pulse Media | Below 3.00 in H1 and H2 FY2026 | 2027-01-12 | 1,117,194.08 |
| **Total** | | | **5,520,920.95** |

Every other supplier is wrong. The data includes deliberate decoys, each of which catches one naive reading:

| Decoy | The trap |
|---|---|
| SUP032 | Sorting period labels as text (`H2-FY2025` sorts after `H1-FY2026`) |
| SUP037 | Using only the latest period instead of both |
| SUP022 | Using `RECOMMENDATION = 'Not Recommended'` instead of the score rule |
| SUP034 | Counting asset/warranty incidents instead of PO-linked ones |
| SUP008 | At risk, but its contract ends between 90 and 120 days out (a wider window) |
| SUP030 | At risk, but its expiring contract is already *Under Renewal* |
| SUP050 | At risk, but its expiring contract is *Auto-renew* |

| Rung | Expected |
|---|---|
| 1 No tools | Can't answer |
| 2 Semantic views | Can't answer, or answers wrongly. CONTRACTS, SUPPLIER_ASSESSMENTS and INCIDENT_LOG aren't in either semantic view, and "at risk" is defined only in a process document. This is the hard edge of the curated layer |
| 3 Sense | The four suppliers above. In the trace: `cortex_sense` returns the at-risk definition (supplier management doc), the expiring-soon window (contract renewal doc), CONTRACTS/ASSESSMENTS/INCIDENT_LOG table entries and query patterns; then `system_execute_sql` |
| 4 SV + Sense | The four suppliers. This is the realistic customer pattern: keep your semantic views and add Sense for the long tail |

**What to show in the trace (Snowsight agent playground or CoWork):** expand the `cortex_sense` tool result. Each filter in the final SQL traces back to a document:

| Filter | Comes from |
|---|---|
| `< 3.00` in **both** H1 and H2 FY2026 | `supplier_management_process.md` §4(a) and §3.1 |
| PO-linked incidents only | `supplier_management_process.md` §4.1 |
| `Active`, not `Auto-renew`, within 90 days | `contract_renewal_process.md` §3 |
| `STATUS = 'Approved'`, FY = July–June | glossary, semantic view |

## Bonus questions

| Question | Where the answer lives | Expected |
|---|---|---|
| *What's our supplier risk score for the top 5 suppliers?* | Only in the Streamlit app code | SUP014 44.3, SUP013 42.6, SUP001 41.8, SUP030 41.6, SUP005 37.7 |
| *Which buyers are splitting POs to avoid approval thresholds in FY2026?* | Procurement approval policy §3 + query patterns | Uses the 3-day, $4,000–$5,000, same buyer/supplier/spend code rule |
| *Which budget lines had a material overrun in FY2026?* | Budget governance standard §5 | Both >10% **and** >$50,000 |

## If the Sense agent misses Q2

**What a test run actually looked like.** In the end-to-end test of this repo, the Sense agent always called `cortex_sense`, got the definitions back and cited them. It got both at-risk rules right, including the 8-PO validity rule, PO-linked incidents and correct period ordering. But it didn't always apply every **exclusion** in the expiring-soon definition:

- With the literal wording "active contracts expiring in the next 90 days", it kept **SUP050** (an Auto-renew contract). It flagged the Auto-renew nuance itself and offered the strict watchlist view.
- With the wording "contracts expiring soon", it included an *Under Renewal* contract and picked up **SUP030**.

Treat this as part of the story, not something to hide:

- **Turn it into the eval point.** This is exactly the kind of miss the eval in [lab 03](03-eval.md) measures (Q2 scored between 0.25 and 0.75 across runs). The right answer depends on rules that live only in a document. Sense retrieves them; consistent application is what the eval and feedback loop improve.
- **Use the follow-up.** Ask *"Using the strict At-Risk Renewal Watchlist definition, which at-risk suppliers have contracts expiring soon, and what's their FY2026 spend?"*. In the test run this returned exactly the four suppliers and $5,520,920.95, with every exclusion cited. It's the most reliable wording if you need the exact answer on stage.
- **Record feedback.** In Cortex Code: `$cortex-sense resume PROCUREMENT record feedback: expiring soon excludes Auto-renew and Under Renewal contracts`. Corrections are served back with future lookups.

**Other checks:**

1. **Is the build finished?** Run `$cortex-sense resume PROCUREMENT check build` in Cortex Code. A fresh context returns no documents until it's built (about 15 minutes in the test run, but it can take hours).
2. **Did it call `cortex_sense`?** If `ask` shows only `system_execute_sql`, the agent skipped retrieval. Re-ask; the orchestration instruction makes the call mandatory.
3. **Rung 2 passed Q2?** That would mean someone added the uncurated tables to a semantic view. Don't: the gap is the point of the demo.
