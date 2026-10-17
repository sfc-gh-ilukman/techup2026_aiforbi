# Lab 04 · Business Ontology

**Time:** 30–45 min · **Needs:** phase A finished (no need to wait for phase B)

Cortex Sense *assembles* context automatically from everything around your data. Business Ontology is the other half of the story: the **governed** vocabulary that stewards approve. It holds what "spend", "at-risk supplier" or "material overrun" mean, how those concepts relate, and which tables and semantic view metrics implement them.

Throughout this lab, `<DB>` is your demo database (default `PEAKFIT_SENSE_DEMO`) and `<DOMAIN>` is your ontology domain (default `PEAKFIT_PROCUREMENT`). Run `python3 scripts/lab.py names` to see yours.

| Part | What you do | Persona |
|---|---|---|
| A | Tour the domain the lab built | Steward / SE |
| B | Read it from SQL | Developer |
| C | Build ontology content yourself with Cortex Code | Builder |
| D | Use the ontology to answer questions | Analyst |
| E | How it fits with Cortex Sense | Everyone |

---

## A. Tour the domain (Snowsight)

Phase A step `40_ontology` built `<DOMAIN>` from [`ontology/peakfit_ontology.json`](../ontology/peakfit_ontology.json). The read-back from the published graph should say:

```
graph read-back: 24/24 nodes, 30/30 relationships, 28/28 representations
```

| Kind | Nodes |
|---|---|
| **Entities (12)** | Supplier, Purchase Order, Supplier Invoice, Contract, Buyer, Fitness Centre, Spend Code, GL Account, Budget Line, Supplier Assessment, Incident, Asset |
| **Metrics (6)** | Total Spend, Invoiced Amount, Maverick Spend, Budget Variance, Supplier Performance Score, Supplier Risk Score |
| **Terms (6)** | Financial Year, At-Risk Supplier, Expiring-Soon Contract, At-Risk Renewal Watchlist, PO Splitting, Material Overrun |

In Snowsight, open **Business Ontology** (Catalog area; the exact menu label can vary by release) and select `<DOMAIN>`.

1. **Graph view.** Relationships are typed, not a sea of `RELATED_TO`. Look for:
   - *Total Spend* **MEASURES** *Purchase Order*
   - *Total Spend* **HAS_VARIANT** *Maverick Spend*
   - *Supplier Performance Score* **DERIVES** *Supplier Risk Score*
   - *At-Risk Renewal Watchlist* **HAS_PART** *At-Risk Supplier* and *Expiring-Soon Contract*
2. **Open *Fitness Centre*.** Its synonyms (Centre, Club, Gym, Cost Centre, Profit Centre) are how one concept survives five names in the business.
3. **Open *Total Spend*.** It's a METRIC with a governed formula (`SUM(AMOUNT) WHERE STATUS = 'Approved' …`), exclusions, and a representation pointing at the `TOTAL_SPEND` metric in the `PROCUREMENT_ANALYST` semantic view.
4. **Open *At-Risk Supplier*.** The definition carries both rules from PF-PROC-SMP-004, plus the traps (recommendation and compliance status don't count). No column in the data says "at risk"; this definition is the only place the rule lives in the catalog.
5. **Open *Supplier Risk Score*.** Its representation is the Streamlit app, because the formula only exists in the app code. The description says plainly that it's *not* the at-risk definition.

**Talking point:** the ontology is the *schema of meaning*: concepts, types and relationships. The instances stay in the tables, and **representations** connect the two.

---

## B. Read it from SQL

The ontology is fully scriptable through scalar `SYSTEM$` functions (use `SELECT`, never `CALL`):

```sql
-- Summary of every domain
SELECT SYSTEM$GET_GLOSSARY_SUMMARY();

-- One node, with relationships and representations inline
SELECT SYSTEM$GET_GLOSSARY_TERM('<DOMAIN>.At-Risk Supplier');

-- The domain graph as rows
SELECT t.value:name::STRING AS node, t.value:itemKind::STRING AS kind
FROM TABLE(FLATTEN(PARSE_JSON(
  SYSTEM$GET_GLOSSARY_GRAPH('{"domainName":"<DOMAIN>"}')):terms)) t
ORDER BY kind, node;

-- What a node is represented by
SELECT SYSTEM$GET_GLOSSARY_TERM_ASSETS('<DOMAIN>.Total Spend');
```

Open `.build/sql/40_ontology.sql` to see exactly how the domain was built:

1. Reset the domain.
2. `SYSTEM$CREATE_GLOSSARY_DOMAIN`.
3. `SYSTEM$DRAFT_GLOSSARY_TERM` for each node (every node starts as a **draft**).
4. `SYSTEM$APPROVE_ALL_GLOSSARY_TERMS`, scoped to this session and domain (the **steward approval** step).
5. `SYSTEM$CREATE_GLOSSARY_RELATIONSHIP` with typed relationships.
6. `SYSTEM$CREATE_GLOSSARY_ASSOCIATION` for the representations.
7. A read-back from `SYSTEM$GET_GLOSSARY_GRAPH`.

The read-back matters: an `error: false` reply isn't proof that a write persisted, so the lab counts what is actually in the graph.

To change the domain, edit `ontology/peakfit_ontology.json` and run `python3 scripts/lab.py run 40_ontology`.

---

## C. Build it yourself with Cortex Code

This is the builder experience. Cortex Code's **business-ontology** skill extracts candidates, runs a quality gate (typed relationships, no invented domains, grounded definitions), drafts, asks you to approve, and reads the graph back.

Use a **new domain of your own**, for example `<PREFIX>_PROCUREMENT_SANDBOX`, so you don't overwrite the lab's domain. Paste the prompts one at a time.

### C1. Extract nodes from the business documents

```
Using the business-ontology skill, import ontology nodes into a new domain
<PREFIX>_PROCUREMENT_SANDBOX from the business process documents on stage
@<DB>.RAW.DOCS. Focus on business rules that are not visible in the column
names. Show me the candidates and the quality-gate findings before drafting.
```

What to point out:
- **Domain is never invented.** You named it, so every candidate is marked `USER_DECLARED`.
- **Quality-gate findings come before any write**, as BLOCK, GATE or ADVISE.
- Approve a subset and leave the rest as drafts. Drafts aren't visible in the published graph until approved.

### C2. Bootstrap from the semantic views and find drift

```
Using the business-ontology skill, bootstrap ontology nodes from the semantic
views in <DB>.ANALYTICS into <PREFIX>_PROCUREMENT_SANDBOX, and report any drift
against the <DOMAIN> domain.
```

The `sv-ingest` path derives concepts from the semantic view join graph (not one node per table) and classifies drift between semantic view expressions and governed definitions.

### C3. Relate and represent

```
In <PREFIX>_PROCUREMENT_SANDBOX, relate Contract to Expiring-Soon Contract as a
variant, and represent Contract with table <DB>.PUBLIC.CONTRACTS.
```

### C4. Change a governed definition (the steward flow)

```
In <DOMAIN>, change the description of Material Overrun to add: "Lines in the
in-progress financial year are not assessed until the year closes." Save it as
an edit for review, don't apply it yet.
```

An ACTIVE node is never edited in place: Cortex Code opens an **edit card**, the live definition stays as it is, and a steward approves the card (try `approve the pending edit on Material Overrun`).

### C5. Register a source that keeps feeding the ontology

```
Register @<DB>.RAW.DOCS as an ontology source for <PREFIX>_PROCUREMENT_SANDBOX.
```

### C6. Promote Cortex Sense concepts (after phase B)

```
Promote the concepts from my Cortex Sense context
<DB>.CORTEX_SENSE.PROCUREMENT into <PREFIX>_PROCUREMENT_SANDBOX.
```

This is the bridge from *assembled* context to *governed* context: Sense found the Supplier Risk Score formula in the app code, and a steward can now make it official.

When you're done, clean up your sandbox: `delete the domain <PREFIX>_PROCUREMENT_SANDBOX and everything in it`.

---

## D. Use the ontology to answer questions

In a fresh Cortex Code chat:

| Ask | Expected (from the governed nodes) |
|---|---|
| *"Using our business ontology, what counts as an at-risk supplier at PeakFit?"* | Rule (a): Supplier Performance Score below 3.00 in **each** of the two most recent completed half-years. Rule (b): **3+** High/Critical incidents attributed through **purchase orders** in the last six months. The recommendation, compliance status and asset-only incidents don't count. Source: PF-PROC-SMP-004 |
| *"What's the difference between Total Spend and Invoiced Amount, and which one do I use for budget reporting?"* | Total Spend = Approved PO value ex GST (PO_TRANSACTIONS, `TOTAL_SPEND` metric). Invoiced Amount = invoice value (PO_INVOICES). Budget Variance **derives** from Total Spend, so use Total Spend |
| *"Is a budget line that's 25% over but $20,000 over a material overrun?"* | No. Both conditions (>10% **and** >$50,000) must hold. PF-FIN-STD-006 |
| *"What do we mean by spend, and what was it in FY2026?"* | The definition from the *Total Spend* node, then $188,621,151.95 |

For the last question, Cortex Code reads the node first, then queries the data.

**Before and after:** ask the first question in an account with no ontology (or before running Part A) and Cortex Code guesses from column names, typically something like "RECOMMENDATION = 'Not Recommended'", which is exactly the trap PF-PROC-SMP-004 warns about.

---

## E. How it fits with Cortex Sense

| | Cortex Sense context | Business Ontology |
|---|---|---|
| **What** | Retrieval context assembled automatically from tables, semantic views, docs, apps and query history | Governed vocabulary: definitions, typed relationships, representations |
| **Who** | A builder scopes it, the build assembles it | Stewards draft, review and approve it |
| **Changes** | Re-build; corrections through feedback | Draft, then approve; edit cards for live nodes |
| **Consumers** | Cortex Code (`cortex_sense`), agents with `EnableCortexSense` | Cortex Code (business-ontology skill, `SYSTEM$GET_GLOSSARY_*`), Snowsight |

Be precise with technical audiences:

- The `ontology_node` documents you see in Cortex Sense results are **extracted by the Sense build itself** from the docs, the app and the semantic views. They are **not** read from Business Ontology.
- Cortex Sense accepts a `business_ontology` scope source, but the build **does not index ontology content yet**. Treat the integration as roadmap, not as something to demo.
- Agents: this lab has not verified that a Cortex Agent reads Business Ontology at runtime. Cortex Code does, through the skill. To give an agent governed definitions today, wrap `SYSTEM$GET_GLOSSARY_TERM` in a custom tool. That's an optional exercise.
- The flow that works today: Sense discovers (C6 promotes its concepts), stewards govern in the ontology, and governed definitions flow back into semantic views and column comments (ask Cortex Code to *"sync node descriptions to column comments"*).
