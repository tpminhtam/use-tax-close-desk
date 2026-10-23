"""Load the Halide Labs synthetic dataset into Snowflake (HALIDE_TAX.RAW).

Run (from the build/ folder):
    uv run --with "snowflake-connector-python[pandas]" --with pyyaml python load.py --connection hackathon

Options:
    --connection NAME   connection name in ~/.snowflake/connections.toml (default: hackathon)
    --role ROLE         role to use (default: HALIDE_BUILDER, created by sql/00_setup.sql)
    --warehouse WH      warehouse (default: HALIDE_WH)
    --policies          ALSO load policies/*.md straight into AGENT.POLICY_CHUNKS
                        (fallback path for Cortex Search if AI_PARSE_DOCUMENT gives trouble)
                        and upload policies/pdf/*.pdf + *.md to @AGENT.POLICY_STAGE
    --policies-only     only do the policies step
    --evals-only        only upload evals/eval_config.yaml to @HALIDE_TAX.EVALS.EVAL_CONFIG
    --dry-run           print the SQL, do not connect

Prereq: sql/00_setup.sql has been run (database, schemas, warehouse, roles exist).
All amounts in the CSVs are INTEGER MINOR UNITS (USD/EUR/SGD cents; JPY has exponent 0).
"""

from __future__ import annotations

import argparse
import re
import shutil
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
DATA = HERE / "data"
POLICIES = HERE / "policies"
DB = "HALIDE_TAX"

# Column order MUST match the CSV header order (COPY maps by position).
TABLES: dict[str, tuple[str, str]] = {
    "ACCOUNTS": ("accounts.csv", """
        CODE VARCHAR(10), NAME VARCHAR(100), TYPE VARCHAR(20), NORMAL_BALANCE VARCHAR(10),
        STATEMENT VARCHAR(30), CATEGORY VARCHAR(50), CONTROL_TYPE VARCHAR(30),
        OPEN_ITEM_MANAGED BOOLEAN, MANUAL_POSTING VARCHAR(20)"""),
    "ENTITIES": ("entities.csv", """
        ID VARCHAR(5), NAME VARCHAR(100), LEGAL_NAME VARCHAR(200), COUNTRY VARCHAR(2),
        ENTITY_CURRENCY VARCHAR(3), GROUP_CURRENCY VARCHAR(3), ROLE VARCHAR(200)"""),
    "PARTIES": ("parties.csv", """
        ID VARCHAR(20), NAME VARCHAR(100), PARTY_TYPE VARCHAR(20), ROLES VARCHAR(100),
        COUNTRY VARCHAR(2), DEFAULT_CURRENCY VARCHAR(3), INDUSTRY VARCHAR(100)"""),
    "DOCUMENTS": ("documents.csv", """
        NUMBER VARCHAR(30), DOC_TYPE VARCHAR(30), ENTITY_ID VARCHAR(5), ENTITY_NAME VARCHAR(100),
        PARTY VARCHAR(100), CURRENCY VARCHAR(3), DOCUMENT_DATE DATE, STATUS VARCHAR(30),
        TAXABLE_MINOR NUMBER(38,0), TAX_MINOR NUMBER(38,0), ACCRUED_MINOR NUMBER(38,0),
        TREATMENTS VARCHAR(100)"""),
    "TAX_LINES": ("tax_lines.csv", """
        DOCUMENT_NUMBER VARCHAR(30), LINE_REF NUMBER(38,0), REGIME VARCHAR(20),
        JURISDICTION_CODE VARCHAR(20), JURISDICTION_NAME VARCHAR(100), LEVEL VARCHAR(20),
        TAX_TYPE VARCHAR(20), TREATMENT VARCHAR(30), TAXABLE_BASE_MINOR NUMBER(38,0),
        RATE NUMBER(9,6), TAX_MINOR NUMBER(38,0), ACCRUAL BOOLEAN, VENDOR_CHARGED_MINOR NUMBER(38,0),
        RULE_ID VARCHAR(50), MATCH_LEVEL NUMBER(3,0)"""),
    "JOURNAL_ENTRIES": ("journal_entries.csv", """
        NUMBER VARCHAR(30), ENTITY_ID VARCHAR(5), BOOK_CODE VARCHAR(10), ENTRY_TYPE VARCHAR(5),
        POSTING_DATE DATE, DOCUMENT_DATE DATE, CURRENCY VARCHAR(3), HEADER_TEXT VARCHAR(500),
        SOURCE_DOCUMENT VARCHAR(30), STATUS VARCHAR(20), RULE_SET VARCHAR(100), POSTED_BY VARCHAR(50)"""),
    "JOURNAL_LINES": ("journal_lines.csv", """
        ENTRY_NUMBER VARCHAR(30), LINE_NO NUMBER(38,0), ENTITY_ID VARCHAR(5), BOOK_CODE VARCHAR(10),
        POSTING_DATE DATE, ACCOUNT_CODE VARCHAR(10), ACCOUNT_NAME VARCHAR(100),
        AMOUNT_MINOR NUMBER(38,0), CURRENCY VARCHAR(3), ENTITY_AMOUNT_MINOR NUMBER(38,0),
        ENTITY_CURRENCY VARCHAR(3), GROUP_AMOUNT_MINOR NUMBER(38,0), GROUP_CURRENCY VARCHAR(3),
        QUANTITY NUMBER(38,6), UOM VARCHAR(20), TAX_JURISDICTION VARCHAR(20), CUSTOMER VARCHAR(20),
        SUPPLIER VARCHAR(20), PRODUCT VARCHAR(20), COST_CENTER VARCHAR(20), DEPARTMENT VARCHAR(20),
        REGION VARCHAR(20), OPEN_ITEM BOOLEAN, SOURCE_DOCUMENT VARCHAR(30), LINE_TYPE VARCHAR(30),
        RULE_ID VARCHAR(100), RULE_MATCH_LEVEL NUMBER(3,0), DESCRIPTION VARCHAR(500)"""),
    "REGISTRATIONS": ("registrations.csv", """
        OWNER_KIND VARCHAR(10), OWNER_ID VARCHAR(20), REGIME VARCHAR(20), JURISDICTION VARCHAR(10),
        NUMBER VARCHAR(50), SCHEME VARCHAR(50), VALIDATION_STATUS VARCHAR(20), EFFECTIVE_FROM DATE"""),
    "PRINCIPALS": ("principals.csv", """
        ID VARCHAR(50), KIND VARCHAR(10), DISPLAY_NAME VARCHAR(100), TITLE VARCHAR(100),
        ROLES VARCHAR(200)"""),
}

EXPECTED_ROWS = {
    "ACCOUNTS": 51, "ENTITIES": 4, "PARTIES": 35, "DOCUMENTS": 70, "TAX_LINES": 608,
    "JOURNAL_ENTRIES": 133, "JOURNAL_LINES": 1147, "REGISTRATIONS": 24, "PRINCIPALS": 7,
}

FILE_FORMAT = (
    "TYPE = CSV SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '\"' "
    "NULL_IF = ('') EMPTY_FIELD_AS_NULL = TRUE TRIM_SPACE = FALSE "
    "ERROR_ON_COLUMN_COUNT_MISMATCH = TRUE"
)


def connect(args):
    import snowflake.connector  # imported lazily so --dry-run works without the package

    conn = snowflake.connector.connect(connection_name=args.connection)
    cur = conn.cursor()
    for stmt in (f"USE ROLE {args.role}", f"USE WAREHOUSE {args.warehouse}", f"USE DATABASE {DB}"):
        print(">", stmt)
        cur.execute(stmt)
    return conn


def run(cur, sql: str, dry: bool):
    print(">", " ".join(sql.split())[:160])
    if dry:
        return []
    cur.execute(sql)
    try:
        return cur.fetchall()
    except Exception:
        return []


def normalised_copy(src: Path, dst_dir: Path) -> Path:
    """Copy a CSV to a temp dir with no spaces in the path and LF line endings."""
    dst = dst_dir / src.name
    dst.write_bytes(src.read_bytes().replace(b"\r\n", b"\n"))
    return dst


def load_tables(cur, dry: bool):
    tmp = Path(tempfile.mkdtemp(prefix="halide_"))
    run(cur, f"CREATE STAGE IF NOT EXISTS {DB}.RAW.LOAD_STAGE", dry)
    run(cur, f"CREATE OR REPLACE FILE FORMAT {DB}.RAW.CSV_FMT {FILE_FORMAT}", dry)
    for table, (fname, cols) in TABLES.items():
        fq = f"{DB}.RAW.{table}"
        local = normalised_copy(DATA / fname, tmp)
        run(cur, f"CREATE OR REPLACE TABLE {fq} ({cols})", dry)
        run(cur, f"PUT 'file://{local.as_posix()}' @{DB}.RAW.LOAD_STAGE/{table.lower()}/ "
                 "AUTO_COMPRESS = TRUE OVERWRITE = TRUE", dry)
        res = run(cur, f"COPY INTO {fq} FROM @{DB}.RAW.LOAD_STAGE/{table.lower()}/ "
                       f"FILE_FORMAT = (FORMAT_NAME = '{DB}.RAW.CSV_FMT') "
                       "ON_ERROR = 'ABORT_STATEMENT' FORCE = TRUE", dry)
        if not dry:
            n = run(cur, f"SELECT COUNT(*) FROM {fq}", dry)[0][0]
            flag = "OK" if n == EXPECTED_ROWS[table] else f"MISMATCH (expected {EXPECTED_ROWS[table]})"
            print(f"   {table}: {n} rows  {flag}   copy result: {res[:1]}")
    shutil.rmtree(tmp, ignore_errors=True)


def load_reference(cur, dry: bool):
    """rates.yml -> RAW.RATE_COMPONENTS ; answer_key.json + yml -> RAW.REFERENCE_FILES (VARIANT)."""
    import json

    run(cur, f"""CREATE OR REPLACE TABLE {DB}.RAW.RATE_COMPONENTS (
        JURISDICTION_CODE VARCHAR(20), JURISDICTION_NAME VARCHAR(100), REGIME VARCHAR(20),
        COUNTRY VARCHAR(2), REGION VARCHAR(5), COMPONENT_LEVEL VARCHAR(20), COMPONENT_NAME VARCHAR(200),
        RATE NUMBER(9,6), EFFECTIVE_FROM DATE, EFFECTIVE_TO DATE)""", dry)
    try:
        import yaml
    except ImportError:
        print("   pyyaml not installed -> skipping RATE_COMPONENTS (add --with pyyaml)")
        return
    rates = yaml.safe_load((DATA / "rates.yml").read_text())
    rows = []
    for j in rates["jurisdictions"]:
        for c in j["components"]:
            rows.append((j["code"], j["name"], j["regime"], j["country"], j.get("region"),
                         c["level"], c["name"], str(c["rate"]), str(c["effective_from"]),
                         str(c["effective_to"]) if c.get("effective_to") else None))
    if not dry:
        cur.executemany(
            f"INSERT INTO {DB}.RAW.RATE_COMPONENTS VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)", rows)
    print(f"   RATE_COMPONENTS: {len(rows)} rows")

    run(cur, f"CREATE OR REPLACE TABLE {DB}.RAW.REFERENCE_FILES (FILE_NAME VARCHAR, CONTENT VARIANT)", dry)
    payloads = {
        "answer_key.json": json.loads((DATA / "answer_key.json").read_text()),
        "rates.yml": rates,
        "process_definitions.yml": yaml.safe_load((DATA / "process_definitions.yml").read_text()),
    }
    if not dry:
        for name, obj in payloads.items():
            cur.execute(f"INSERT INTO {DB}.RAW.REFERENCE_FILES SELECT %s, PARSE_JSON(%s)",
                        (name, json.dumps(obj, default=str)))
    print(f"   REFERENCE_FILES: {len(payloads)} rows")


def chunk_markdown(text: str, max_chars: int = 1800) -> list[str]:
    """Split on ## headings, then hard-wrap long sections on paragraph boundaries."""
    sections = re.split(r"\n(?=## )", text)
    title = text.splitlines()[0].lstrip("# ").strip()
    chunks: list[str] = []
    for sec in sections:
        paras, buf = sec.split("\n\n"), ""
        for p in paras:
            if len(buf) + len(p) > max_chars and buf:
                chunks.append(buf.strip())
                buf = ""
            buf += p + "\n\n"
        if buf.strip():
            chunks.append(buf.strip())
    # prefix every chunk with the document title so retrieval keeps context
    return [c if c.startswith("# ") else f"[{title}]\n{c}" for c in chunks]


def load_policies(cur, dry: bool):
    files = sorted(POLICIES.glob("*.md"))
    if not files:
        print("   no policies/*.md found")
        return
    # 1) upload originals to the stage (for the AI_PARSE_DOCUMENT path in sql/02_search.sql)
    tmp = Path(tempfile.mkdtemp(prefix="halide_pol_"))
    uploads = list((POLICIES / "pdf").glob("*.pdf")) + files
    for f in uploads:
        local = tmp / f.name
        shutil.copy(f, local)
        run(cur, f"PUT 'file://{local.as_posix()}' @{DB}.AGENT.POLICY_STAGE "
                 "AUTO_COMPRESS = FALSE OVERWRITE = TRUE", dry)
    run(cur, f"ALTER STAGE {DB}.AGENT.POLICY_STAGE REFRESH", dry)
    shutil.rmtree(tmp, ignore_errors=True)

    # 2) fallback: chunk markdown locally and insert straight into POLICY_CHUNKS
    run(cur, f"""CREATE TABLE IF NOT EXISTS {DB}.AGENT.POLICY_CHUNKS (
        CHUNK_ID VARCHAR, POLICY_ID VARCHAR, POLICY_TITLE VARCHAR, FILE_NAME VARCHAR,
        CHUNK_INDEX NUMBER, CHUNK VARCHAR, SOURCE_METHOD VARCHAR,
        LOADED_AT TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP())""", dry)
    run(cur, f"DELETE FROM {DB}.AGENT.POLICY_CHUNKS WHERE SOURCE_METHOD = 'markdown_direct'", dry)
    total = 0
    for f in files:
        text = f.read_text()
        title = text.splitlines()[0].lstrip("# ").strip()
        m = re.search(r"Policy ID:\s*\**\s*([A-Z0-9-]+)", text)
        pid = m.group(1) if m else f.stem.upper()
        rows = [(f"{pid}:md:{i}", pid, title, f.name.replace(".md", ".pdf"), i, c, "markdown_direct")
                for i, c in enumerate(chunk_markdown(text))]
        if not dry:
            cur.executemany(
                f"INSERT INTO {DB}.AGENT.POLICY_CHUNKS "
                "(CHUNK_ID, POLICY_ID, POLICY_TITLE, FILE_NAME, CHUNK_INDEX, CHUNK, SOURCE_METHOD) "
                "VALUES (%s,%s,%s,%s,%s,%s,%s)", rows)
        total += len(rows)
        print(f"   {f.name}: {len(rows)} chunks ({pid})")
    print(f"   POLICY_CHUNKS (markdown_direct): {total} chunks")


def upload_evals(cur, dry: bool):
    """PUT evals/eval_config.yaml to @EVALS.EVAL_CONFIG (no compression) for EXECUTE_AI_EVALUATION."""
    cfg = HERE / "evals" / "eval_config.yaml"
    tmp = Path(tempfile.mkdtemp(prefix="halide_eval_"))
    local = tmp / cfg.name
    shutil.copy(cfg, local)
    run(cur, f"CREATE STAGE IF NOT EXISTS {DB}.EVALS.EVAL_CONFIG", dry)
    run(cur, f"PUT 'file://{local.as_posix()}' @{DB}.EVALS.EVAL_CONFIG "
             "AUTO_COMPRESS = FALSE OVERWRITE = TRUE", dry)
    shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--connection", default="hackathon")
    ap.add_argument("--role", default="HALIDE_BUILDER")
    ap.add_argument("--warehouse", default="HALIDE_WH")
    ap.add_argument("--policies", action="store_true")
    ap.add_argument("--policies-only", action="store_true")
    ap.add_argument("--evals-only", action="store_true", help="only upload evals/eval_config.yaml")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if args.dry_run:
        cur, conn = None, None
    else:
        conn = connect(args)
        cur = conn.cursor()
    if args.evals_only:
        upload_evals(cur, args.dry_run)
    elif not args.policies_only:
        load_tables(cur, args.dry_run)
        load_reference(cur, args.dry_run)
    if args.policies or args.policies_only:
        load_policies(cur, args.dry_run)
    if conn:
        conn.close()
    print("done.")


if __name__ == "__main__":
    sys.exit(main())
