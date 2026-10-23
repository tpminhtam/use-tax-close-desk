# RUNBOOK: Halide Labs use-tax close desk (Snowflake × Claude)

Run everything top to bottom. Each step lists where to run it, the role, the expected output and roughly how long it takes. Folder: `~/Desktop/Intelligence at Work Hackathon/build/`.

> **Order matters.** Run `03` **after** `04`, because the semantic view includes `AGENT.PROPOSED_JOURNALS`.
> Order: **00 → load.py → 01 → 04 → 02 → 03 → 05 → 06 → 07 → 08**.

## Step 0: connection (5 min)

1. In Snowsight, open avatar → *Connect a tool to Snowflake* and copy the account identifier, e.g. `MYORG-MYACCOUNT`.
2. Create `~/.snowflake/connections.toml`. Snowflake reads this path only if the `~/.snowflake` folder exists; otherwise macOS uses `~/Library/Application Support/snowflake/`.

   ```bash
   mkdir -p ~/.snowflake && touch ~/.snowflake/connections.toml && chmod 0600 ~/.snowflake/connections.toml
   ```

   Contents:

   ```toml
   [hackathon]
   account = "MYORG-MYACCOUNT"
   user = "YOUR_USER"
   password = "YOUR_PASSWORD"      # or a PAT secret
   role = "ACCOUNTADMIN"
   warehouse = "COMPUTE_WH"
   ```

   The file **must be chmod 0600**; a 0644 file is a hard error. Trial accounts allow password login. If MFA blocks the Python login, add `authenticator = "externalbrowser"`, or create a PAT and use it as the password.
3. Run `uv --version`. Use `uv run`, not the pyenv python.

## Step 1: `sql/00_setup.sql` (Snowsight worksheet, ACCOUNTADMIN, 3 min)

Paste the file and choose **Run All**. If it stops on an error, fix that statement and continue from there.

Expected:

- `SHOW PARAMETERS` then the `ALTER ACCOUNT ... ANY_REGION` succeeds.
- The roles are created.
- The three `AI_COMPLETE` smoke tests return text like `ok`.
- **A NULL result means an error**, because AI_COMPLETE returns NULL instead of raising. Check cross-region first, then try `claude-haiku-4-5` or `claude-opus-4-6`.

Write down which model ids work. The agent uses `claude-sonnet-5`; the fallback is `claude-sonnet-4-6`.

## Step 2: load the data and policies (terminal, 2 min)

```bash
cd ~/Desktop/"Intelligence at Work Hackathon"/build
uv run --with "snowflake-connector-python[pandas]" --with pyyaml python load.py --connection hackathon --policies
```

Expected row counts, each marked `OK`: ACCOUNTS 51, ENTITIES 4, PARTIES 35, DOCUMENTS 70, TAX_LINES 608, JOURNAL_ENTRIES 133, JOURNAL_LINES 1147, REGISTRATIONS 24, PRINCIPALS 7, RATE_COMPONENTS 27, REFERENCE_FILES 3. You should also see 14 files PUT to POLICY_STAGE and `POLICY_CHUNKS (markdown_direct): 38 chunks`.

If the Python connection fails, load the CSVs with Snowsight's *Load data* UI instead. The tables have to match `TABLES` in `load.py`, so creating them via the script is still preferred.

## Step 3: `sql/01_core_views.sql` (worksheet, 1 min)

The final checks should show these close actions:

| Close action | Count | Detail |
|---|---|---|
| ACCRUE_USE_TAX | 1 | SINV-US-2026-000012, USD 3,465.00 |
| USE_TAX_ACCRUED | 2 | |
| VENDOR_OVERCHARGE | 1 | SINV-US-2026-000013, USD 103,500.00 |
| SELF_ASSESSED_VAT_IN_GL | 3 | |
| VENDOR_TAX_OK | 10 | |
| NO_TAX_DUE | 11 | |

Also check:

- The JPY check returns `22000.00`.
- The unbalanced-entries query returns 0 rows.

## Step 4: `sql/04_tools.sql` (worksheet, 1 min)

This creates the tables and 4 procedures. Then run the commented smoke tests **after `USE SECONDARY ROLES NONE;`**:

| Call (as TAX_ANALYST) | Expected status |
|---|---|
| `PROPOSE_USE_TAX_ACCRUAL('SINV-US-2026-000012')` | `proposed`, USD 3,465.00, Dr 6100 / Cr 2410 |
| Same call again | `already_proposed` |
| `PROPOSE_USE_TAX_ACCRUAL('SINV-US-2026-000008')` | `already_in_gl` (US-RE-2026-000008) |
| `FLAG_VENDOR_OVERCHARGE('SINV-US-2026-000013', '...')` | `flagged`, USD 103,500.00 |
| `APPROVE_PROPOSAL('PJ-00001')` | **insufficient privileges**. This is correct and shows SoD working |

Then switch to `USE ROLE CONTROLLER` and run `APPROVE_PROPOSAL('PJ-00001')`. You will get `blocked`, because maker-checker sees that you prepared it yourself. To approve, let the MCP service user make the proposal (step 8) and approve it as yourself. Before the demo, **reset** the tables (see below).

## Step 5: `sql/02_search.sql` (worksheet, 3 to 5 min)

- **Path A:** `AI_PARSE_DOCUMENT` on the 7 PDFs. Check that `POLICY_DOCS_PARSED` has 7 rows with non-NULL text.
- **Fallback:** if parsing returns NULL or errors, skip Path A and keep the `markdown_direct` chunks.
- Then `CREATE CORTEX SEARCH SERVICE`. The index builds on create.
- Run the `SEARCH_PREVIEW` test. Expect HL-TAX-POL-004 first for the approval question.

## Step 6: `sql/03_semantic_view.sql` (worksheet, 2 min)

- If CREATE fails pointing at `AI_VERIFIED_QUERIES`, delete the block between `VQ START` and `VQ END` and re-run.
- If it fails on anything else, use **Semantic View Autopilot** in Snowsight (AI & ML → Cortex Analyst) with the same 6 views. Name it `HALIDE_TAX.CORE.TAX_CLOSE_SV` and add a few synonyms.
- The `SEMANTIC_VIEW(...)` check query should match step 3.

## Step 7: `sql/05_agent.sql` (worksheet, 3 min)

1. `CREATE AGENT` should succeed. It does not validate the tools.
2. Run the `DATA_AGENT_RUN` smoke tests as TAX_ANALYST. The September use tax answer should mention SINV-US-2026-000012 and USD 3,465.00.
3. If you see `warnings` with code 399569, a tool is not accessible to the role; check the grants.
4. If the procedure tools don't fire, open Snowsight → AI & ML → Agents → USE_TAX_CLOSE_DESK → Edit → Tools. Add the custom tools there, then `DESCRIBE AGENT`.
5. The script sets your DEFAULT_ROLE to TAX_ANALYST and DEFAULT_WAREHOUSE to HALIDE_WH, which CoWork and OAuth need. To undo: `ALTER USER <you> SET DEFAULT_ROLE = 'ACCOUNTADMIN';`
6. Open CoWork at https://ai.snowflake.com and choose *Use-Tax Close Desk*.

## Step 8: `sql/06_mcp.sql` plus `MCP_CLIENTS.md` (10 min)

1. `CREATE MCP SERVER` should succeed. If it errors on the `required:` lines, delete them.
2. Create the service user, network policy and PAT. **Copy `token_secret` immediately**; it is shown once.
3. Run the `MCP_URL` query.
4. Follow `MCP_CLIENTS.md`: run the `curl tools/list` check, then `claude mcp add ...`.
5. In Claude Code: "Propose the use tax accrual for SINV-US-2026-000012". Then approve as yourself: `USE ROLE CONTROLLER; CALL HALIDE_TAX.AGENT.APPROVE_PROPOSAL('PJ-0000x');`

## Step 9: `sql/07_governance.sql` (worksheet, 3 min)

1. JP_TAX_ANALYST sees only the 6 JP invoices. Run `USE SECONDARY ROLES NONE` first.
2. Registration numbers are masked for the JP role and inside agent or MCP sessions.
3. The Guardrails `AI_SETTINGS` statement needs Enterprise edition; skip it if it errors.
4. The observability query lists agent spans. The UI is at Agents → Monitoring.

## Step 10: evals (10 min, mostly waiting)

```bash
/usr/bin/python3 -I evals/make_evals.py        # already generated; re-run only if data changes
uv run --with "snowflake-connector-python[pandas]" python load.py --connection hackathon --evals-only
```

Then run `sql/08_evals.sql` in a worksheet: create the table, insert 12 rows, run `SYSTEM$CREATE_EVALUATION_DATASET`, `START`, poll `STATUS` until COMPLETED, then run the results query. The UI is at Agents → USE_TAX_CLOSE_DESK → Evaluations.

## Demo reset (run before recording or judging)

```sql
USE ROLE HALIDE_BUILDER;
DELETE FROM HALIDE_TAX.AGENT.PROPOSED_JOURNAL_LINES;
DELETE FROM HALIDE_TAX.AGENT.PROPOSED_JOURNALS;
DELETE FROM HALIDE_TAX.AGENT.VENDOR_TAX_FLAGS;
-- keep AUDIT_LOG (it is the story), or: DELETE FROM HALIDE_TAX.AGENT.AUDIT_LOG;
USE SECONDARY ROLES NONE;
```

Proposal ids keep counting from the sequence (PJ-00002 and so on). That is fine; read the id from the agent's answer.

## Known pitfalls (from the docs, Oct 23 2026)

1. **Cross-region is required for Claude.** No Claude model is native in NA or APAC regions, so set `CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION'` (ACCOUNTADMIN). `claude-sonnet-5-5` works with ANY_REGION only. Azure and GCP accounts need ANY_REGION for any Claude model.
2. **Silent failures.**
   - `AI_COMPLETE` and `AI_PARSE_DOCUMENT` return NULL on error.
   - `CREATE AGENT` does not validate tools.
   - Inaccessible tools are silently dropped (warning 399569).
   - Custom-tool privilege errors appear only when the tool is called.
3. **Secondary roles default to ALL.** Your "TAX_ANALYST" session then also has CONTROLLER and HALIDE_BUILDER, which hides the SoD error and the row access policy. Run `USE SECONDARY ROLES NONE` for every role demo.
4. **ACCOUNTADMIN bypasses model RBAC**, so test models as a non-admin role. ACCOUNTADMIN is also **blocked from OAuth**: set DEFAULT_ROLE to TAX_ANALYST for the Claude.ai connector.
5. **Agent spec details.**
   - `tool_resources` keys must equal the tool `name` exactly.
   - Unquoted warehouse names go in CAPS.
   - `CREATE OR REPLACE AGENT` drops grants and evaluation history. Re-run the GRANT, or iterate with `ALTER AGENT`.
6. **Model lists differ by surface.** opus-5-5 and sonnet-5-5 are available in AI_COMPLETE (preview) but **not** as agent orchestration models. Cortex Analyst picks its own model (Claude Sonnet 4.6 first).
7. **AI_PARSE_DOCUMENT does not accept `.md`.** That is why the policies are rendered as PDFs. The stage needs `ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')` and a directory table.
8. **Semantic view DDL.**
   - Clause order is fixed (FACTS before DIMENSIONS).
   - Every expression needs its table alias.
   - A referenced table needs a PRIMARY KEY.
   - `ALTER` can only rename or comment, so use `CREATE OR REPLACE ... COPY GRANTS`.
9. **Evals.**
   - The default metric version v1 uses legacy `claude-4-sonnet`, which fails on new accounts, so pin `v3`. This is done in `eval_config.yaml`.
   - Don't put a `dataset:` block in the YAML; it breaks the second run.
   - Ground truth must be VARIANT (use `PARSE_JSON`).
   - The eval role needs `EXECUTE TASK` (granted in 00).
10. **PATs.**
    - A SERVICE user needs a network policy (06 creates an allow-all policy for that user only).
    - `invalid_client` usually means a network policy problem.
    - The PAT secret is shown once.
11. **MCP.**
    - The host uses hyphens, not underscores.
    - Responses are SSE since Aug 2026, so curl needs `Accept: application/json, text/event-stream`.
    - Agent responses can exceed 200 KB.
    - Don't expose `SYSTEM_EXECUTE_SQL` next to the agent.
12. **CoWork visibility.** With no CoWork object, users see every agent they have USAGE on. If one exists, run `ALTER SNOWFLAKE INTELLIGENCE ... ADD AGENT`. CoWork uses your default role and warehouse.
13. **Cost.** The Cortex Search service bills while it exists. Drop it after judging, and suspend the warehouse.

## If short on time, cut in this order

1. Claude.ai / Desktop OAuth connector. Keep Claude Code with the PAT; it is faster and more reliable.
2. `07` governance. At most, run just the JP row access policy part, which is a 30-second demo moment.
3. The `08` SQL eval path. Use Snowsight → Agents → Evaluations UI with 3 to 5 questions from `evals/eval_questions.json`.
4. Path A of `02` (AI_PARSE_DOCUMENT). Keep the markdown fallback chunks.
5. The `AI_VERIFIED_QUERIES` block in `03`. Or use Autopilot.
6. The code execution tool, the `data_to_chart` tool and the JP role.

**Minimum viable demo (about 60 min):** 00 → load → 01 → 04 → 02 (fallback) → 03 → 05 → CoWork, plus `CALL APPROVE_PROPOSAL` as CONTROLLER.
