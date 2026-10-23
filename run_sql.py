"""Run a .sql file against the `hackathon` connection, one statement at a time.

Usage:  ../.venv/bin/python run_sql.py sql/00_setup.sql [--from N] [--to M] [--keep-going]
Prints each statement's first line and up to 15 result rows. Stops on the first
error unless --keep-going, and tells you the statement number to resume from.
"""
import argparse
import io
import sys

import snowflake.connector
from snowflake.connector.util_text import split_statements

ap = argparse.ArgumentParser()
ap.add_argument("file")
ap.add_argument("--from", dest="start", type=int, default=1)
ap.add_argument("--to", dest="end", type=int, default=10**9)
ap.add_argument("--keep-going", action="store_true")
ap.add_argument("--rows", type=int, default=15)
args = ap.parse_args()

text = open(args.file).read()
stmts = [s for s, _ in split_statements(io.StringIO(text), remove_comments=True) if s.strip()]
errors = 0
with snowflake.connector.connect(connection_name="hackathon") as conn:
    cur = conn.cursor()
    for i, stmt in enumerate(stmts, 1):
        if i > args.end:
            break
        if i < args.start:
            # still replay session-level statements so later ones behave the same
            if stmt.lstrip().upper().startswith(("USE ", "SET ")):
                cur.execute(stmt)
            continue
        head = " ".join(stmt.split())[:110]
        try:
            cur.execute(stmt)
        except Exception as e:  # noqa: BLE001
            errors += 1
            print(f"\n!! [{i}/{len(stmts)}] ERROR in: {head}\n   {str(e)[:700]}")
            if not args.keep_going:
                print(f"\nStopped. Fix it, then resume with --from {i}")
                sys.exit(1)
            continue
        print(f"\n[{i}/{len(stmts)}] {head}")
        if cur.description:
            cols = [c[0] for c in cur.description]
            rows = cur.fetchmany(args.rows)
            print("   " + " | ".join(cols)[:300])
            for r in rows:
                print("   " + " | ".join("" if v is None else str(v) for v in r)[:600])
print(f"\nDone: {len(stmts)} statements, {errors} errors.")
