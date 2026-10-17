# Lab 03 · Eval: proof at scale

**Time:** 15 min hands-on, then 10–30 min of unattended run time · **Needs:** phase B done and the Sense build finished

A demo shows one good answer. An eval shows the lift is **measured, isolated and repeatable**. Every question is answered twice:

- **baseline**: Cortex Sense off (catalog search + SQL only)
- **context**: Cortex Sense on

An LLM judge grades each answer against a golden computed with SQL.

## The eval set

`python3 scripts/lab.py sense` already saved [`eval/eval.yaml`](../eval/eval.yaml) to the context's stage, so the cortex-sense skill finds it. It has 15 questions, all pinned *as at 31 October 2026*:

| Tier | # | Tests | Where the answer lives |
|---|---|---|---|
| answer | q1 | FY2026 spend by state | semantic view (control: should be equal) |
| answer | q2 | At-risk suppliers with contracts expiring in 90 days | 2 process docs + 3 uncurated tables |
| answer | q3, q4, q10 | At-risk rule (a), rule (b), watch items | supplier management doc |
| answer | q5 | Contracts expiring soon | contract renewal doc |
| answer | q6 | PO-splitting buyers | approval policy + query patterns |
| answer | q7, q12 | Material overruns, Over Budget lines | budget governance doc |
| answer | q8 | Tail spend | glossary |
| answer | q9 | Highest Supplier Risk Score, High band | Streamlit app only |
| answer | q11 | Headcount and FTE | semantic view (control) |
| retrieval | q13–q15 | Which table / where is it calculated / thresholds | table entries, app, policy doc |

Goldens were computed with SQL in the build database (never in the demo database, whose query history Sense mines). Data generation is deterministic, so they hold in every account.

## Run it

In Cortex Code:

```
$cortex-sense resume PROCUREMENT run eval
```

The skill answers every question with and without the context, judges each answer, and saves the run next to the context. Tips:

- **Run it ahead of time**, not live. Each question is a hosted agent session.
- The eval answers questions against `<DB>`, so it adds to the query history. That's fine after the build, but don't run it *before* the build.
- To compare two runs: `$cortex-sense resume PROCUREMENT diff eval`.

## Read the result

**Lead with `answer_lift`** (answer-tier accuracy with context minus baseline). Show retrieval separately: a strong baseline can often *find* the right table, but it can't apply rules it has never seen.

Reference run on the original build of this dataset (15 questions, LLM judge):

| | Baseline | Context | Lift |
|---|---|---|---|
| Answer tier (q1–q12) | 0.45 | 0.83 | **+0.38** |
| Retrieval tier (q13–q15) | 0.65 | 1.00 | +0.35 |
| Overall | 0.49 | 0.87 | +0.38 |

Your numbers will differ: an LLM judges each answer and agents aren't deterministic. Expect the same shape:

- **Big wins** on rules that only live in docs (q2, q3, q7, q10) and on the app-only metric (q9).
- **Ties** on the semantic view controls (q1, q11).
- **Hard questions** that both arms can miss (q6 PO splitting, q8 tail spend: 28 vs 29 suppliers is a classic off-by-one on "inclusive of the crossing supplier").

The misses are useful too. Open one with `$cortex-sense resume PROCUREMENT` and describe what went wrong. The skill routes it to **refine** (change the scope) or **feedback** (a stored correction), which is the improvement loop you'd run with a customer.

## Talking points

- **No strawman:** the baseline gets catalog search and SQL, not "no tools".
- **The goldens are SQL, not prose.** Anyone can re-run `eval/eval.yaml`'s `golden_sql`.
- **Per-question deltas** map to source types: docs vs query history vs app vs uncurated tables.
