"""Ask the Cortex Agent a question from the terminal and show what it did.

Usage:  ../.venv/bin/python ask_agent.py "Which invoices need use tax accrued?" [--role TAX_ANALYST]
Prints the tools the agent called (with inputs), any warnings, and the final answer.
"""
import argparse
import json

import snowflake.connector

ap = argparse.ArgumentParser()
ap.add_argument("question")
ap.add_argument("--role", default="TAX_ANALYST")
ap.add_argument("--agent", default="HALIDE_TAX.AGENT.USE_TAX_CLOSE_DESK")
ap.add_argument("--raw", action="store_true", help="dump the full JSON response")
args = ap.parse_args()

body = json.dumps({"messages": [{"role": "user", "content": [{"type": "text", "text": args.question}]}]})

with snowflake.connector.connect(connection_name="hackathon") as conn:
    cur = conn.cursor()
    cur.execute("USE SECONDARY ROLES NONE")
    cur.execute(f"USE ROLE {args.role}")
    cur.execute("USE WAREHOUSE HALIDE_WH")
    cur.execute("SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(%s, %s)", (args.agent, body))
    resp = json.loads(cur.fetchone()[0])

if args.raw:
    print(json.dumps(resp, indent=2)[:20000])

for w in resp.get("warnings", []) or []:
    print("WARNING:", json.dumps(w)[:300])

for item in resp.get("content", []):
    kind = item.get("type")
    if kind == "tool_use":
        tu = item.get("tool_use", {})
        print(f"-> tool {tu.get('name')}  input={json.dumps(tu.get('input'))[:200]}")
    elif kind == "tool_result":
        tr = item.get("tool_result", {})
        status = tr.get("status", "")
        print(f"<- result {tr.get('name')} {status}")
    elif kind == "text":
        print("\n" + item.get("text", ""))
