---
name: peakfit-lab
description: "Set up, check, continue and tear down the PeakFit Cortex Sense + Business Ontology lab in this repo. Use when the user says: set up the PeakFit lab, set up the lab, deploy the demo, continue the PeakFit lab, is the lab ready, lab status, check the lab, run the agents, reset the lab, tear down the lab, remove the PeakFit lab. Drives scripts/lab.py step by step and verifies every result."
---

# PeakFit lab

This repo builds a complete Cortex Sense + Business Ontology demo (PeakFit Australia procurement) in the user's Snowflake account. All work goes through `scripts/lab.py`. Do **not** hand-write or improvise SQL for setup: the scripts are deterministic and checked, and improvised SQL against the demo database pollutes the query history that Cortex Sense mines.

Run every command from the repo root with `python3 scripts/lab.py ...`. Each step logs to `.build/logs/<step>.log`; on failure, read that log before saying anything.

## Intents

| User says | Do |
|---|---|
| set up / deploy / start the lab | **Setup** (below), then stop after phase A |
| continue the lab / is it ready / build the context | **Phase B** |
| status / check the lab | `python3 scripts/lab.py status` and summarise |
| ask the agents / run the ladder | **Agent ladder** |
| tear down / remove / reset | **Teardown** |

## Setup

1. **Prerequisites.** Run `which snow python3`. If `snow` is missing, tell the user to install the Snowflake CLI (`pip install snowflake-cli` or `brew install snowflake-cli`) and stop.
2. **Connection.** Run `snow connection list` and show the names. Use `ask_user_question` once for three things, with these defaults:
   - connection: the CLI default connection, or the one matching the account the user is connected to in Cortex Code
   - role: `SYSADMIN` (ACCOUNTADMIN also works). The role creates and owns every lab object.
   - prefix: `PEAKFIT`. Every object is named `<PREFIX>_...`, so several people can share one demo account. Suggest the user's initials if the account is shared.
3. **Init.** If `config/lab.config.yaml` doesn't exist yet: `python3 scripts/lab.py init --connection <c> --role <r> --prefix <p>`. If it does exist, show it and ask whether to keep it.
4. **Preflight.** `python3 scripts/lab.py preflight`. Render the result as a short table.
   - `FAIL` on Cortex Sense or Business Ontology: stop. These need to be enabled on the account by an admin, and the lab can't fake them.
   - `WARN` on ACCOUNT_USAGE: offer to run `GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE <role>;` (needs ACCOUNTADMIN). It's optional: without it Cortex Sense skips query-history mining, but the seeded query library still gives it SQL patterns.
   - `WARN` on an existing database: confirm the user wants to rebuild it.
5. **Phase A.** Run `python3 scripts/lab.py deploy` with `run_in_background: true` (it takes roughly 10 to 20 minutes on an XS warehouse), then poll with `bash_output` and post a one-line update each time a step finishes. Steps, in order:
   - `00`–`05` generate the synthetic data in a temporary build database
   - `06b_gate` checks the golden answers (all must PASS before anything is promoted)
   - `07` clones the tables into `<PREFIX>_SENSE_DEMO`, then `08` drops the build database
   - `10`–`11` create the two semantic views
   - `12` uploads the docs, the query library and the Streamlit app to stages
   - `13`–`15` run the analyst query workload (query history for Sense to mine)
   - `30` creates the four agents, and `40` builds the Business Ontology domain
   If a step fails, read its log, explain the cause in one sentence, fix what you can (e.g. a missing grant), and resume with `python3 scripts/lab.py deploy --from <step>`.
6. **Report.** Run `python3 scripts/lab.py status` and show the checklist. Then tell the user:
   - Query history takes 45 minutes to a few hours to reach ACCOUNT_USAGE, so the Cortex Sense context is created in phase B.
   - Meanwhile they can do `labs/04-business-ontology.md` (it's ready now) and open the Streamlit app.
   - When ready, say **"continue the PeakFit lab"**.

## Phase B

1. `python3 scripts/lab.py history`. If it reports fewer workload queries than it wants and the role *can* read ACCOUNT_USAGE, say how many are visible and suggest waiting. The user may choose to proceed anyway.
2. `python3 scripts/lab.py sense`. This registers the `PROCUREMENT` context in `<PREFIX>_SENSE_DEMO.CORTEX_SENSE`, saves the scope manifest and the eval set, and queues the build.
3. Tell the user the build runs in the background, from minutes to a few hours depending on load. Do not promise a time. To check it: `$cortex-sense resume PROCUREMENT check build` (the `cortex-sense` skill), or try a `cortex_sense` lookup scoped to `<PREFIX>_SENSE_DEMO.CORTEX_SENSE.PROCUREMENT` and see whether documents come back.
4. Point to `labs/01-cortex-sense.md` and `labs/02-agent-ladder.md`.

## Agent ladder

`python3 scripts/lab.py ask <naked|sv|sense|sv_sense> "<question>"` runs one question through one agent and prints the tools it called and its answer. The two hero questions and their expected answers are in `labs/02-agent-ladder.md`. Run them in order (naked, sv, sense) and compare each answer with the expected one. A Sense agent that answers without a `cortex_sense` call, or before the context build has finished, will miss Q2. Say so rather than calling it a failure of the product.

## Teardown

Teardown permanently drops `<PREFIX>_SENSE_DEMO`, the warehouse, the ontology domain and the Cortex Sense context. Show the names from `python3 scripts/lab.py names` and ask the user to **type the prefix** to confirm. Only on an exact match run `python3 scripts/lab.py teardown --yes`.

## Rules

- Never edit files under `.build/`; they're regenerated on every run. Change the templates in `sql/`, `docs/`, `sense/`, `ontology/` or `eval/` instead.
- Never run golden-answer or validation SQL against `<PREFIX>_SENSE_DEMO`. It would put the answers into the query history that Sense learns from.
- Report what the scripts report. If a gate or a check fails, say so plainly with the failing line.
