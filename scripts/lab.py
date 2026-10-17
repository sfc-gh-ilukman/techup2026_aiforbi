#!/usr/bin/env python3
"""PeakFit Cortex Sense lab driver.

One entry point for every setup step, so the lab runs the same way from the
Cortex Code skill, from a terminal, or in CI. Standard library only; needs the
Snowflake CLI (`snow`) on PATH with a working connection.

    python3 scripts/lab.py init --connection my_conn --role SYSADMIN --prefix PEAKFIT
    python3 scripts/lab.py preflight          # account checks, nothing created
    python3 scripts/lab.py deploy             # phase A: data, SVs, docs, app, workload, agents, ontology
    python3 scripts/lab.py history            # has the workload reached ACCOUNT_USAGE yet?
    python3 scripts/lab.py sense              # phase B: create the Cortex Sense context + start the build
    python3 scripts/lab.py status             # what exists, with expected counts
    python3 scripts/lab.py ask sense "Which at-risk suppliers ..."   # smoke-test an agent
    python3 scripts/lab.py teardown --yes     # drop everything the lab created

Lower-level commands: names, render, run <step> [<step> ...], gate.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BUILD = REPO / ".build"
LOGS = BUILD / "logs"
CONFIG = REPO / "config" / "lab.config.yaml"
EXAMPLE_CONFIG = REPO / "config" / "lab.config.example.yaml"

TEMPLATE_DIRS = ["sql", "docs", "apps", "sense", "ontology", "eval"]
TEXT_SUFFIXES = {".sql", ".md", ".py", ".yaml", ".yml", ".toml", ".json", ".txt"}
IDENT = re.compile(r"^[A-Z][A-Z0-9_]{0,40}$")
TOKEN = re.compile(r"\{\{([A-Z_]+)\}\}")
TRANSIENT = re.compile(r"Connection is closed|250002 \(08003\)")

# Phase A, in order. Each entry is a file in sql/ (without .sql).
PHASE_A = [
    "00_setup",
    "01_dimensions",
    "02_procurement_facts",
    "03_finance_workforce",
    "04_ancillary",
    "05_planted_scenarios",
    "06b_gate",            # checked against EXPECTED before anything is promoted
    "07_promote",
    "08_drop_build",
    "10_sv_procurement",
    "11_sv_finance_workforce",
    "12_docs_and_app",
    "13_workload_batch1",
    "14_workload_batch2",
    "15_workload_batch3",
    "30_agents",
    "40_ontology",
]

# Golden answers. Data generation is deterministic, so these hold in any account.
EXPECTED = {
    "INTEGRITY_VIOLATIONS": 0,
    "Q2_SUPPLIERS": "SUP014,SUP015,SUP026,SUP040",
    "Q2_TOTAL_SPEND": "5520920.95",
    "Q1_TOTAL_SPEND": "188621151.95",
    "RISK_TOP5": "SUP014=44.3,SUP013=42.6,SUP001=41.8,SUP030=41.6,SUP005=37.7",
}

# Minimum number of workload queries in ACCOUNT_USAGE before the Sense build is worth starting.
HISTORY_READY = 40

# Steps whose output is parsed (run with --format json).
JSON_STEPS = {"40_ontology"}


# --------------------------------------------------------------------------- config + names


def read_config(path: Path = CONFIG) -> dict[str, str]:
    """Parse the flat `key: value` config file (no PyYAML dependency)."""
    if not path.exists():
        sys.exit(f"No config at {path.relative_to(REPO)}. Run: python3 scripts/lab.py init --connection <name>")
    cfg: dict[str, str] = {}
    for raw in path.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        key, sep, value = line.partition(":")
        if not sep:
            sys.exit(f"Bad config line: {raw!r}")
        cfg[key.strip()] = value.strip().strip("'\"")
    for key in ("connection", "role", "prefix"):
        if not cfg.get(key):
            sys.exit(f"Config is missing '{key}'")
    return cfg


def derive_names(cfg: dict[str, str]) -> dict[str, str]:
    prefix, role = cfg["prefix"].upper(), cfg["role"].upper()
    for label, value in (("prefix", prefix), ("role", role)):
        if not IDENT.match(value):
            sys.exit(f"Invalid {label} {value!r}: letters, digits and underscores only, starting with a letter.")
    return {
        "PREFIX": prefix,
        "ROLE": role,
        "CONNECTION": cfg["connection"],
        "DB": f"{prefix}_SENSE_DEMO",
        "BUILD_DB": f"{prefix}_SENSE_BUILD",
        "WH": f"{prefix}_SENSE_WH",
        "SENSE_CONTEXT": "PROCUREMENT",
        "SENSE_SCHEMA": "CORTEX_SENSE",
        "ONTOLOGY_DOMAIN": f"{prefix}_PROCUREMENT",
        "AGENT_NAKED": "PEAKFIT_NAKED_AGENT",
        "AGENT_SV": "PEAKFIT_SV_AGENT",
        "AGENT_SENSE": "PEAKFIT_SENSE_AGENT",
        "AGENT_SV_SENSE": "PEAKFIT_SV_SENSE_AGENT",
        "BUILD_DIR": BUILD.as_posix(),
    }


def names() -> dict[str, str]:
    return derive_names(read_config())


# --------------------------------------------------------------------------- render


def render(n: dict[str, str]) -> int:
    """Write every template to .build/ with placeholders filled in."""
    if BUILD.exists():
        for child in BUILD.iterdir():
            if child.name != "logs":
                shutil.rmtree(child) if child.is_dir() else child.unlink()
    count, unknown = 0, set()
    for top in TEMPLATE_DIRS:
        for src in sorted((REPO / top).rglob("*")):
            if not src.is_file() or "__pycache__" in src.parts or src.name == ".DS_Store":
                continue
            dst = BUILD / src.relative_to(REPO)
            dst.parent.mkdir(parents=True, exist_ok=True)
            if src.suffix not in TEXT_SUFFIXES:
                shutil.copy2(src, dst)
                continue

            def sub(m: re.Match[str]) -> str:
                if m.group(1) not in n:
                    unknown.add(f"{m.group(1)} in {src.relative_to(REPO)}")
                    return m.group(0)
                return n[m.group(1)]

            dst.write_text(TOKEN.sub(sub, src.read_text()))
            count += 1
    if unknown:
        sys.exit("Unknown placeholders:\n  " + "\n  ".join(sorted(unknown)))
    write_sense_sql(n)
    write_ontology_sql(n)
    (BUILD / "names.json").write_text(json.dumps(n, indent=2) + "\n")
    return count


def sql_literal(value: str) -> str:
    return "'" + value.replace("\\", "\\\\").replace("'", "''") + "'"


def dollar(value: str) -> str:
    if "$$" in value:
        sys.exit(f"Value must not contain '$$': {value[:60]}")
    return f"$${value}$$"


def write_ontology_sql(n: dict[str, str]) -> None:
    """Generate .build/sql/40_ontology.sql from the rendered ontology/peakfit_ontology.json.

    Every statement returns (STEP, R): STEP labels the call, R is the JSON envelope.
    The ontology functions report failures inside R ({"error": true}) instead of
    raising, so lab.py checks every row (see check_ontology).
    """
    spec = json.loads((BUILD / "ontology" / "peakfit_ontology.json").read_text())
    dom = spec["domain"]["name"]
    fq = lambda term: sql_literal(f"{dom}.{term}")
    lines = [
        "-- Generated by scripts/lab.py from ontology/peakfit_ontology.json. Do not edit.",
        f"-- Re-running resets the {dom} domain to the spec.",
        f"USE ROLE {n['ROLE']};",
        f"USE WAREHOUSE {n['WH']};",
        "",
        "-- 0. Reset (errors here are expected on a first run)",
    ]
    domain_filter = sql_literal(json.dumps({"domainFilter": dom}))
    for fn in ("DELETE_ALL_GLOSSARY_RELATIONSHIPS", "DELETE_ALL_GLOSSARY_ASSOCIATIONS",
               "DELETE_ALL_GLOSSARY_TERM_DRAFTS", "DELETE_ALL_GLOSSARY_TERMS"):
        lines.append(f"SELECT 'reset:{fn}' AS STEP, SYSTEM${fn}({domain_filter}) AS R;")
    lines.append(f"SELECT 'reset:DELETE_GLOSSARY_DOMAIN' AS STEP, SYSTEM$DELETE_GLOSSARY_DOMAIN({sql_literal(dom)}) AS R;")
    lines += ["", "-- 1. Domain",
              f"SELECT 'domain' AS STEP, SYSTEM$CREATE_GLOSSARY_DOMAIN({sql_literal(dom)}, "
              f"{sql_literal(spec['domain']['description'])}) AS R;", "", "-- 2. Nodes (draft)"]
    for node in spec["nodes"]:
        payload = {"name": node["name"], "domainName": dom, "itemKind": node["itemKind"],
                   "description": node["description"], "synonyms": node.get("synonyms", [])}
        if node["itemKind"] == "METRIC":
            for key in ("formula", "exclusions", "formulaSource"):
                if node.get(key):
                    payload[key] = node[key]
        lines.append(f"SELECT 'draft:{node['name']}' AS STEP, SYSTEM$DRAFT_GLOSSARY_TERM({dollar(json.dumps(payload))}) AS R;")
    approve_filter = sql_literal(json.dumps({"sessionId": "CURRENT_SESSION", "domain": dom}))
    lines += ["", "-- 3. Steward approval: this session's drafts in this domain only",
              f"SELECT 'approve' AS STEP, SYSTEM$APPROVE_ALL_GLOSSARY_TERMS('[]', 'ACTIVE', {approve_filter}) AS R;",
              "", "-- 4. Typed relationships"]
    for src, tgt, rtype in spec["relationships"]:
        lines.append(f"SELECT 'rel:{src} {rtype} {tgt}' AS STEP, "
                     f"SYSTEM$CREATE_GLOSSARY_RELATIONSHIP({fq(src)}, {fq(tgt)}, {sql_literal(rtype)}) AS R;")
    lines += ["", "-- 5. Representations (links to the Snowflake objects that implement each node)"]
    for node in spec["nodes"]:
        for ref in node.get("representations", []):
            label = ref.get("subObjectName") or ref.get("dimensionName") or ref.get("objectName")
            lines.append(f"SELECT 'rep:{node['name']} -> {label}' AS STEP, SYSTEM$CREATE_GLOSSARY_ASSOCIATION("
                         f"{fq(node['name'])}, {sql_literal(json.dumps(ref))}, 'REPRESENTED_AS') AS R;")
    graph_filter = sql_literal(json.dumps({"domainName": dom, "includeAssociations": True}))
    lines += ["", "-- 6. Read back from the published graph (the only proof a write persisted)",
              f"SELECT 'readback' AS STEP, SYSTEM$GET_GLOSSARY_GRAPH({graph_filter}) AS R;"]
    (BUILD / "sql" / "40_ontology.sql").write_text("\n".join(lines) + "\n")


def check_ontology(n: dict[str, str], out: str) -> None:
    """Fail on any non-reset error envelope, then report counts read back from the graph."""
    data = json.loads(out[out.find("["):])
    spec = json.loads((BUILD / "ontology" / "peakfit_ontology.json").read_text())
    errors, graph = [], {}
    for rows in data:
        if not rows or "STEP" not in rows[0]:
            continue
        step, raw = rows[0]["STEP"], rows[0]["R"]
        res = json.loads(raw) if isinstance(raw, str) else (raw or {})
        if step == "readback":
            graph = res
        elif res.get("error") and not step.startswith("reset:"):
            errors.append(f"{step}: {res.get('errorMessage')}")
        elif step == "approve" and res.get("failed"):
            errors.append(f"approve: {res['failed']} node(s) failed")
    want_nodes = len(spec["nodes"])
    want_rels = len(spec["relationships"])
    want_reps = sum(len(x.get("representations", [])) for x in spec["nodes"])
    got = (len(graph.get("terms", [])), len(graph.get("relationships", [])), len(graph.get("associations", [])))
    print(f"     graph read-back: {got[0]}/{want_nodes} nodes, {got[1]}/{want_rels} relationships, "
          f"{got[2]}/{want_reps} representations")
    if errors or got != (want_nodes, want_rels, want_reps):
        sys.exit("Ontology build incomplete:\n  " + "\n  ".join(errors or ["read-back counts differ from the spec"]))


def builder_call(action: str, n: dict[str, str], **extra: object) -> str:
    """SQL for one SYSTEM$CORTEX_AGENT_CORTEX_CONTEXT_BUILDER call (dollar-quoted JSON literal)."""
    params = {"name": n["SENSE_CONTEXT"], "database_name": n["DB"], "schema_name": n["SENSE_SCHEMA"], **extra}
    payload = json.dumps({"action": action, "parameters": params})
    if "$$" in payload:
        sys.exit("Manifest content must not contain '$$'")
    return f"SELECT TRY_PARSE_JSON(SYSTEM$CORTEX_AGENT_CORTEX_CONTEXT_BUILDER($${payload}$$)) AS RESULT"


def write_sense_sql(n: dict[str, str]) -> None:
    """Generate .build/sql/20_sense_context.sql from the rendered manifest."""
    now = datetime.now(timezone.utc)
    version = f"v-{now:%Y%m%d-%H%M%S}-lab"
    stamp = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    manifest = (BUILD / "sense" / "scope.yaml").read_text()
    header = (
        f"business_domain: {n['SENSE_CONTEXT']}\n"
        f"created_at: '{stamp}'\nupdated_at: '{stamp}'\n"
        f"version_id: {version}\ndescription_synced_version: {version}\n"
    )
    manifest = header + manifest.replace(f"business_domain: {n['SENSE_CONTEXT']}\n", "", 1)
    (BUILD / "sense" / "scope.yaml").write_text(manifest)
    eval_yaml = (BUILD / "eval" / "eval.yaml").read_text()
    eval_version = re.search(r"^version_id: (\S+)", eval_yaml, re.M).group(1)
    stmts = [
        "-- Generated by scripts/lab.py from sense/scope.yaml and eval/eval.yaml. Do not edit.",
        f"USE ROLE {n['ROLE']};",
        f"USE WAREHOUSE {n['WH']};",
        f"CREATE SCHEMA IF NOT EXISTS {n['DB']}.{n['SENSE_SCHEMA']};",
        builder_call("create-context", n) + ";",
        builder_call("put-stage-file", n, path="scope.yaml", content=manifest, overwrite=True) + ";",
        builder_call("put-stage-file", n, path=f"scope_{version}.yaml", content=manifest, overwrite=False) + ";",
        builder_call("force-reprocess", n) + ";",
        builder_call("put-stage-file", n, path="eval.yaml", content=eval_yaml, overwrite=True) + ";",
        builder_call("put-stage-file", n, path=f"eval-{eval_version}.yaml", content=eval_yaml, overwrite=False) + ";",
    ]
    (BUILD / "sql" / "20_sense_context.sql").write_text("\n".join(stmts) + "\n")


# --------------------------------------------------------------------------- snow


def snow(n: dict[str, str], *, file: Path | None = None, query: str | None = None,
         as_json: bool = False, log: str | None = None, check: bool = True) -> tuple[int, str]:
    # lab.py renders its own {{...}} placeholders. Turn off the CLI's templating, which
    # would otherwise read text such as 'OH&S' as a variable reference.
    cmd = ["snow", "sql", "-c", n["CONNECTION"], "--enable-templating", "NONE"]
    if as_json:
        cmd += ["--format", "json"]
    cmd += ["-f", str(file)] if file else ["-q", query or ""]
    for attempt in range(3):
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True)
        except FileNotFoundError:
            sys.exit("The Snowflake CLI (`snow`) is not on PATH. Install it: https://docs.snowflake.com/developer-guide/snowflake-cli/installation/installation")
        out = proc.stdout + (("\n" + proc.stderr) if proc.stderr.strip() else "")
        # The CLI occasionally drops a fresh connection before the first statement; retry those.
        if not TRANSIENT.search(out):
            break
        time.sleep(3 * (attempt + 1))
    if log:
        LOGS.mkdir(parents=True, exist_ok=True)
        (LOGS / f"{log}.log").write_text(out)
    if check and proc.returncode != 0:
        tail = "\n".join(out.strip().splitlines()[-15:])
        sys.exit(f"FAILED ({log or 'query'}). Last output:\n{tail}\nFull log: {LOGS.relative_to(REPO)}/{log}.log" if log
                 else f"FAILED:\n{tail}")
    return proc.returncode, out


def query_rows(n: dict[str, str], sql: str, check: bool = True) -> list[dict] | None:
    """Run SQL and return the rows of the last statement, or None on error when check=False."""
    rc, out = snow(n, query=sql, as_json=True, check=check)
    if rc != 0:
        return None
    start = out.find("[")
    data = json.loads(out[start:]) if start >= 0 else []
    if data and isinstance(data[0], list):
        data = data[-1]
    return data


def builder_result(rows: list[dict] | None) -> dict:
    if not rows:
        return {}
    value = rows[0].get("RESULT")
    return json.loads(value) if isinstance(value, str) else (value or {})


# --------------------------------------------------------------------------- commands


def cmd_init(args: argparse.Namespace) -> None:
    if CONFIG.exists() and not args.force:
        print(f"{CONFIG.relative_to(REPO)} already exists (use --force to overwrite):")
        print(CONFIG.read_text())
        return
    text = EXAMPLE_CONFIG.read_text()
    text = re.sub(r"^connection: .*$", f"connection: {args.connection}", text, flags=re.M)
    text = re.sub(r"^role: .*$", f"role: {args.role.upper()}", text, flags=re.M)
    text = re.sub(r"^prefix: .*$", f"prefix: {args.prefix.upper()}", text, flags=re.M)
    CONFIG.write_text(text)
    derive_names(read_config())  # validate
    print(f"Wrote {CONFIG.relative_to(REPO)}")
    cmd_names(args)


def cmd_names(_: argparse.Namespace) -> None:
    n = names()
    for key in ("CONNECTION", "ROLE", "DB", "WH", "SENSE_CONTEXT", "ONTOLOGY_DOMAIN",
                "AGENT_NAKED", "AGENT_SV", "AGENT_SENSE"):
        print(f"  {key:16} {n[key]}")


def cmd_render(_: argparse.Namespace) -> None:
    n = names()
    print(f"Rendered {render(n)} files to .build/ for prefix {n['PREFIX']}")


def check_line(status: str, name: str, detail: str) -> None:
    print(f"  [{status:4}] {name:28} {detail}")


def cmd_preflight(_: argparse.Namespace) -> None:
    n = names()
    print(f"Preflight for connection '{n['CONNECTION']}', role {n['ROLE']}, prefix {n['PREFIX']}\n")
    failures = 0
    rows = query_rows(n, f"USE ROLE {n['ROLE']}; SELECT CURRENT_ACCOUNT_NAME() AS ACCOUNT, CURRENT_USER() AS USR, "
                         f"CURRENT_ROLE() AS ROLE, CURRENT_REGION() AS REGION", check=False)
    if rows:
        r = rows[0]
        check_line("OK", "Connection + role", f"{r['ACCOUNT']} as {r['USR']} ({r['ROLE']}, {r['REGION']})")
    else:
        check_line("FAIL", "Connection + role", f"cannot connect or USE ROLE {n['ROLE']}")
        sys.exit(1)

    res = builder_result(query_rows(n, "SELECT TRY_PARSE_JSON(SYSTEM$CORTEX_AGENT_CORTEX_CONTEXT_BUILDER("
                                       "'{\"action\":\"list-contexts\"}')) AS RESULT", check=False))
    if res and not res.get("error"):
        contexts = (res.get("response_structured") or {}).get("cortex_contexts") or []
        mine = [c for c in contexts if c.get("database_name") == n["DB"]]
        check_line("OK", "Cortex Sense", f"enabled ({len(contexts)} contexts in account"
                                         f"{', lab context already exists' if mine else ''})")
    else:
        failures += 1
        check_line("FAIL", "Cortex Sense", f"not available: {(res.get('error') or {}).get('message', 'call failed')}")

    rows = query_rows(n, "SELECT TRY_PARSE_JSON(SYSTEM$GET_GLOSSARY_SUMMARY()) AS RESULT", check=False)
    summary = builder_result(rows)
    if summary and not summary.get("error"):
        domains = [d["name"] for d in summary.get("domains", [])]
        note = f", {n['ONTOLOGY_DOMAIN']} already exists" if n["ONTOLOGY_DOMAIN"] in domains else ""
        check_line("OK", "Business Ontology", f"enabled ({len(domains)} domains{note})")
    else:
        failures += 1
        check_line("FAIL", "Business Ontology", "not enabled on this account (SYSTEM$GET_GLOSSARY_SUMMARY failed)")

    rows = query_rows(n, f"USE ROLE {n['ROLE']}; SELECT COUNT(*) AS N FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY "
                         "WHERE START_TIME > DATEADD(HOUR, -1, CURRENT_TIMESTAMP())", check=False)
    if rows is not None:
        check_line("OK", "ACCOUNT_USAGE access", "query history readable (Sense can mine query patterns)")
    else:
        check_line("WARN", "ACCOUNT_USAGE access",
                   f"{n['ROLE']} cannot read SNOWFLAKE.ACCOUNT_USAGE. Query-history mining will be skipped. Fix: "
                   f"GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE {n['ROLE']};")

    rows = query_rows(n, f"USE ROLE {n['ROLE']}; SHOW DATABASES LIKE '{n['DB']}'", check=False)
    if rows:
        check_line("WARN", "Existing lab database", f"{n['DB']} exists and will be rebuilt in place")
    else:
        check_line("OK", "Lab database name", f"{n['DB']} is free")

    rows = query_rows(n, f"USE ROLE {n['ROLE']}; SHOW GRANTS TO ROLE {n['ROLE']}", check=False) or []
    privs = {(r.get("privilege"), r.get("granted_on")) for r in rows}
    owner_like = n["ROLE"] in ("ACCOUNTADMIN", "SYSADMIN")
    for priv in ("CREATE DATABASE", "CREATE WAREHOUSE"):
        if owner_like or (priv, "ACCOUNT") in privs:
            check_line("OK", priv, "granted")
        else:
            check_line("WARN", priv, f"not granted directly to {n['ROLE']} (may be inherited; setup will tell)")

    print()
    if failures:
        sys.exit(f"{failures} required feature(s) missing. Ask your account admin to enable them, then re-run.")
    print("Preflight passed. Next: python3 scripts/lab.py deploy")


def run_step(n: dict[str, str], step: str) -> float:
    path = BUILD / "sql" / f"{step}.sql"
    if not path.exists():
        sys.exit(f"No such step: {step} (looked for {path.relative_to(REPO)})")
    t0 = time.time()
    print(f"  -> {step} ...", end="", flush=True)
    _, out = snow(n, file=path, log=step, as_json=step in JSON_STEPS)
    elapsed = time.time() - t0
    print(f" ok ({elapsed:.0f}s)")
    if step == "40_ontology":
        check_ontology(n, out)
    return elapsed


def gate_check(n: dict[str, str]) -> None:
    """Run 06b_gate.sql in the build database and compare it with EXPECTED."""
    _, out = snow(n, file=BUILD / "sql" / "06b_gate.sql", as_json=True, log="06b_gate")
    data = json.loads(out[out.find("["):])
    got = (data[-1] if data and isinstance(data[0], list) else data)[0]
    bad = []
    for key, want in EXPECTED.items():
        have = got.get(key)
        ok = str(have).strip() == str(want)
        print(f"     {'PASS' if ok else 'FAIL'}  {key:22} {have}")
        if not ok:
            bad.append(f"{key}: expected {want}, got {have}")
    if bad:
        sys.exit("Golden-answer gate failed, nothing promoted:\n  " + "\n  ".join(bad))


def cmd_run(args: argparse.Namespace) -> None:
    n = names()
    render(n)
    for step in args.steps:
        step = step.removesuffix(".sql")
        gate_check(n) if step == "06b_gate" else run_step(n, step)


def cmd_gate(_: argparse.Namespace) -> None:
    n = names()
    render(n)
    gate_check(n)


def cmd_deploy(args: argparse.Namespace) -> None:
    n = names()
    render(n)
    steps = PHASE_A
    if args.from_step:
        if args.from_step not in steps:
            sys.exit(f"--from must be one of: {', '.join(steps)}")
        steps = steps[steps.index(args.from_step):]
    print(f"Deploying phase A into {n['DB']} ({len(steps)} steps). Logs: .build/logs/")
    total = 0.0
    for step in steps:
        if step == "06b_gate":
            print("  -> 06b_gate (golden answers)")
            gate_check(n)
            continue
        total += run_step(n, step)
    print(f"\nPhase A complete in {total / 60:.1f} min.")
    print("Query history takes 45 min to a few hours to reach ACCOUNT_USAGE.")
    print("Check with:  python3 scripts/lab.py history   then run:  python3 scripts/lab.py sense")


def cmd_history(_: argparse.Namespace) -> None:
    n = names()
    rows = query_rows(n, f"USE ROLE {n['ROLE']}; SELECT COUNT(*) AS N, MAX(START_TIME)::STRING AS LAST_SEEN "
                         f"FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY WHERE DATABASE_NAME = '{n['DB']}' "
                         "AND QUERY_TAG ILIKE '%persona%' AND START_TIME > DATEADD(DAY, -30, CURRENT_TIMESTAMP())",
                      check=False)
    if rows is None:
        print(f"{n['ROLE']} cannot read SNOWFLAKE.ACCOUNT_USAGE, so Sense will not mine query history.")
        print("You can still build the context now: python3 scripts/lab.py sense")
        return
    count, last = rows[0]["N"], rows[0]["LAST_SEEN"]
    print(f"Workload queries visible in ACCOUNT_USAGE: {count} (last: {last})")
    if count >= HISTORY_READY:
        print("Ready. Next: python3 scripts/lab.py sense")
    else:
        print(f"Not ready yet (want >= {HISTORY_READY}). ACCOUNT_USAGE lags 45 min to a few hours; check again later.")


def cmd_sense(_: argparse.Namespace) -> None:
    n = names()
    render(n)
    path = BUILD / "sql" / "20_sense_context.sql"
    rc, out = snow(n, file=path, as_json=True, log="20_sense_context")
    start = out.find("[")
    results = json.loads(out[start:]) if start >= 0 else []
    labels = ["create-context", "put scope.yaml", "put snapshot", "force-reprocess", "put eval.yaml", "put eval snapshot"]
    calls = [r for r in results if r and "RESULT" in r[0]]
    for label, rows in zip(labels, calls):
        res = builder_result(rows)
        err = (res.get("error") or {}).get("message", "")
        ok = not err or re.search(r"already exists|duplicate", err, re.I)
        print(f"  [{'OK' if ok else 'FAIL'}] {label:16} {err or 'done'}")
        if not ok and label in ("create-context", "put scope.yaml"):
            sys.exit(f"Cortex Sense rejected {label}. Full log: .build/logs/20_sense_context.log")
    print(f"\nContext {n['DB']}.{n['SENSE_SCHEMA']}.{n['SENSE_CONTEXT']} saved; the build runs in the background "
          "(minutes to a few hours).")
    print("Check it in Cortex Code with:  $cortex-sense resume PROCUREMENT check build")


def cmd_status(_: argparse.Namespace) -> None:
    n = names()
    db = n["DB"]
    checks = [
        ("Base tables (15)", f"SELECT COUNT(*) AS N FROM {db}.INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'PUBLIC' AND TABLE_TYPE = 'BASE TABLE'", 15),
        ("Semantic views (2)", f"SHOW SEMANTIC VIEWS IN SCHEMA {db}.ANALYTICS", 2),
        ("Docs on stage (5)", f"SELECT COUNT(*) AS N FROM DIRECTORY(@{db}.RAW.DOCS)", 5),
        ("Query library (1)", f"SELECT COUNT(*) AS N FROM DIRECTORY(@{db}.CORTEX_SENSE.SENSE_SOURCES)", 1),
        ("Streamlit app (1)", f"SHOW STREAMLITS IN SCHEMA {db}.APPS", 1),
        ("Agents (4)", f"SHOW AGENTS IN SCHEMA {db}.ANALYTICS", 4),
    ]
    print(f"Status of {db}\n")
    for label, sql, want in checks:
        rows = query_rows(n, f"USE ROLE {n['ROLE']}; {sql}", check=False)
        have = None if rows is None else (rows[0].get("N") if rows and "N" in rows[0] else len(rows))
        check_line("OK" if have == want else "MISS", label, "missing" if have is None else f"{have}")
    summary = builder_result(query_rows(n, "SELECT TRY_PARSE_JSON(SYSTEM$GET_GLOSSARY_SUMMARY()) AS RESULT", check=False))
    dom = next((d for d in summary.get("domains", []) if d.get("name") == n["ONTOLOGY_DOMAIN"]), None)
    check_line("OK" if dom else "MISS", "Ontology domain",
               f"{dom['termCount']} nodes, {dom['relationshipCount']} relationships, {dom['associationCount']} representations"
               if dom else "missing")
    res = builder_result(query_rows(n, "SELECT TRY_PARSE_JSON(SYSTEM$CORTEX_AGENT_CORTEX_CONTEXT_BUILDER("
                                       "'{\"action\":\"list-contexts\"}')) AS RESULT", check=False))
    ctx = [c for c in (res.get("response_structured") or {}).get("cortex_contexts", [])
           if c.get("database_name") == db and c.get("name") == n["SENSE_CONTEXT"]]
    check_line("OK" if ctx else "MISS", "Cortex Sense context",
               f"{db}.{n['SENSE_SCHEMA']}.{n['SENSE_CONTEXT']}" if ctx else "not created yet (python3 scripts/lab.py sense)")


AGENT_KEYS = {"naked": "AGENT_NAKED", "sv": "AGENT_SV", "sense": "AGENT_SENSE", "sv_sense": "AGENT_SV_SENSE"}


def cmd_ask(args: argparse.Namespace) -> None:
    """Run one question through one lab agent and print the tools it used and its answer."""
    n = names()
    agent = f"{n['DB']}.ANALYTICS.{n[AGENT_KEYS[args.agent]]}"
    body = json.dumps({"messages": [{"role": "user", "content": [{"type": "text", "text": args.question}]}]})
    if "$$" in body:
        sys.exit("Question must not contain '$$'")
    t0 = time.time()
    rows = query_rows(n, f"USE ROLE {n['ROLE']}; USE WAREHOUSE {n['WH']}; "
                         f"SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN('{agent}', $${body}$$) AS R")
    raw = rows[0]["R"]
    resp = json.loads(raw) if isinstance(raw, str) else raw
    tools, texts = [], []
    for item in resp.get("content", []):
        if item.get("type") == "tool_use":
            tools.append(item.get("tool_use", {}).get("name") or item.get("name", "?"))
        elif item.get("type") == "text":
            texts.append(item.get("text", ""))
    print(f"Agent:  {agent}  ({time.time() - t0:.0f}s)")
    print(f"Tools:  {' -> '.join(tools) or '(none)'}\n")
    print("\n".join(texts).strip() or json.dumps(resp, indent=2)[:3000])


def cmd_teardown(args: argparse.Namespace) -> None:
    n = names()
    if not args.yes:
        sys.exit(f"This permanently drops {n['DB']}, {n['BUILD_DB']}, {n['WH']}, the {n['ONTOLOGY_DOMAIN']} ontology "
                 f"domain and the {n['SENSE_CONTEXT']} Sense context in {n['DB']}.\nRe-run with --yes to confirm.")
    render(n)
    res = builder_result(query_rows(n, builder_call("delete-context", n), check=False))
    err = (res.get("error") or {}).get("message", "")
    print(f"  Sense context: {'deleted' if not err else ('already absent' if re.search('not found|does not exist', err, re.I) else err)}")
    run_step(n, "99_teardown")
    print("Teardown complete.")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("init", help="write config/lab.config.yaml")
    s.add_argument("--connection", required=True)
    s.add_argument("--role", default="SYSADMIN")
    s.add_argument("--prefix", default="PEAKFIT")
    s.add_argument("--force", action="store_true")
    s.set_defaults(fn=cmd_init)
    sub.add_parser("names", help="print derived object names").set_defaults(fn=cmd_names)
    sub.add_parser("render", help="render templates to .build/").set_defaults(fn=cmd_render)
    sub.add_parser("preflight", help="check the account is ready").set_defaults(fn=cmd_preflight)
    s = sub.add_parser("deploy", help="phase A")
    s.add_argument("--from", dest="from_step", help="resume from this step")
    s.set_defaults(fn=cmd_deploy)
    s = sub.add_parser("run", help="run individual steps")
    s.add_argument("steps", nargs="+")
    s.set_defaults(fn=cmd_run)
    sub.add_parser("gate", help="re-check golden answers (needs the build DB)").set_defaults(fn=cmd_gate)
    sub.add_parser("history", help="is the workload visible in ACCOUNT_USAGE?").set_defaults(fn=cmd_history)
    sub.add_parser("sense", help="phase B: create the Cortex Sense context").set_defaults(fn=cmd_sense)
    sub.add_parser("status", help="what exists").set_defaults(fn=cmd_status)
    s = sub.add_parser("ask", help="ask one lab agent a question")
    s.add_argument("agent", choices=sorted(AGENT_KEYS))
    s.add_argument("question")
    s.set_defaults(fn=cmd_ask)
    s = sub.add_parser("teardown", help="drop everything")
    s.add_argument("--yes", action="store_true")
    s.set_defaults(fn=cmd_teardown)
    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
