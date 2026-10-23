# Use-Tax Close Desk

**A Claude agent on Snowflake that works the monthly indirect-tax close. It can propose journal entries but never post them, and Snowflake enforces that, not the prompt.**

Built solo at the *Intelligence at Work* hackathon (Snowflake × Anthropic, Oct 23 2026).
Demo video: _link in the submission form_

## The problem

Every month a tax team checks every supplier invoice for one thing: **did the vendor charge the right tax?**

- **No tax on a taxable purchase:** the company owes **use tax**. Someone has to self-assess it, accrue it and get the journal approved.
- **Tax charged that wasn't due:** the company is overpaying. The invoice has to be held, and AP has to get a credit memo from the vendor.

Today this is a spreadsheet exercise:
1. pull invoices and tax lines;
2. find the exceptions;
3. look up the policy;
4. type the journal entry;
5. chase an approval.

When it goes wrong, either a liability goes unrecorded (an audit finding) or cash leaks to vendors. Teams are reluctant to let AI near this work for a fair reason: it touches the general ledger, and the person who prepares an entry must not be the person who approves it.

**Who it's for:** indirect-tax analysts, controllers and AP teams at any company that buys from many vendors. The pattern also fits other close tasks: accruals, reclasses and intercompany.

## What it does

The data belongs to Halide Labs, a fictional AI-compute company with 4 entities (US, Ireland, Japan, Singapore). It has 70 invoices, 608 tax-engine lines, 1,147 GL lines and 7 internal policy memos.

| You say | What happens |
|---|---|
| "What does the September close look like?" | Cortex Analyst queries a semantic view of the tax data. The answer: **SINV-US-2026-000012** (Stackworks) needs **USD 3,465.00** of use tax accrued, and **SINV-US-2026-000013** (Hyperscale Compute) was overcharged **USD 103,500.00**. |
| "What does our policy say to do?" | Cortex Search retrieves the policy memos, which were parsed from PDF with `AI_PARSE_DOCUMENT`. The answer cites the policy by ID (HL-TAX-POL-002). |
| "Run the September close." | The agent proposes the accrual (**PJ-00001**: Dr 6100 / Cr 2410 US use tax payable) and flags the overcharge (**VF-00001**). It ends with a close summary saying who must approve. |
| "Approve and post it." | **Refused.** The agent's role has no approve tool, so no prompt can unlock one. |
| Controller in Snowsight: `CALL APPROVE_PROPOSAL('PJ-00001')` | **Approved.** The audit log shows the agent's service user proposed it and a human approved it. |

The same agent runs in **CoWork** (business users), in **Claude Code / Claude Desktop** through the **Snowflake-managed MCP server** (builders), and from SQL.

## Controls: why a controller could trust it

1. **Claude never decides the number.** The procedure computes the amount from the tax-engine lines. Claude decides what to do and explains why.
2. **The agent has its own identity.** It runs as a Snowflake service user (`HALIDE_AGENT_SVC`, role `TAX_AGENT`) with a role-restricted access token, so its actions are audited like an employee's.
3. **It can only write through two procedures.** No role can insert into or update the proposal tables. The procedures set status = *pending*, build balanced entries, refuse duplicates (`already_proposed`, `already_in_gl`) and log every call.
4. **It can't approve or post.** `APPROVE_PROPOSAL` is granted only to `CONTROLLER`, and maker-checker blocks anyone from approving their own proposal. There is no posting path at all.
5. **Row-level security reaches through the agent.** A Japan analyst sees only Japan's invoices, including through the agent. Tax registration numbers are masked for that role.

## How it is built (the five dimensions)

```
 CoWork (tax analyst)      Claude Code / Desktop (MCP)        Snowsight (controller)
        │                          │  service user + PAT               │
        ▼                          ▼                                    ▼
 ┌──────────────── Cortex Agent: USE_TAX_CLOSE_DESK (Claude Sonnet 5) ───────────────┐
 │ tax_data ─► Cortex Analyst ─► semantic view TAX_CLOSE_SV ─► CORE views ─► RAW ERP  │
 │ policy_search ─► Cortex Search ◄─ chunks ◄─ AI_PARSE_DOCUMENT ◄─ 7 policy PDFs     │
 │ propose_use_tax_accrual / flag_vendor_overcharge ─► owner's-rights procedures      │
 │                         └─► PROPOSED_JOURNALS (pending) · VENDOR_TAX_FLAGS · AUDIT │
 └────────────────────────────────────────────────────────────────────────────────────┘
                     APPROVE_PROPOSAL ── CONTROLLER role only, maker-checker
```

| Dimension | Used |
|---|---|
| Surface | CoWork, Snowsight, Cortex Agent, Claude Code via the Snowflake-managed MCP server |
| Context | Typed RAW tables. CORE views convert integer minor units per currency (JPY has no decimals). A semantic view with synonyms, SQL-generation rules ("never add across currencies") and verified queries. Policy PDFs. |
| Toolkit | Cortex Analyst, Cortex Search, `AI_PARSE_DOCUMENT`, stored procedures as custom tools, MCP |
| Intelligence | Claude Sonnet 5 orchestrates the agent through cross-region inference; `AI_COMPLETE` with structured output |
| Action | Governed write-back through procedures; MCP server exposing the agent, Analyst, Search and the two write tools, with no raw-SQL tool |
| Observability | Agent traces (`GET_AI_OBSERVABILITY_EVENTS`) plus our own `AUDIT_LOG`: who, what, outcome, policy cited |
| Evals | Cortex Agent evaluations on 12 questions. Expected answers are computed by a script from the source CSVs. Two custom LLM judges: *propose-never-post* and *currency correctness*. |
| Identity / Auth | Role hierarchy TAX_AGENT ⊂ TAX_ANALYST ⊂ CONTROLLER; service user with a role-restricted PAT; OAuth public client for Claude.ai |
| Governance | Segregation of duties through grants, an entity row access policy, a masking policy on tax registration numbers, Cortex AI Guardrails (prompt-injection) |

## Evals

12 questions, scored 0 to 1 by Snowflake's agent evaluation. The expected answers are computed by a script from the source CSVs (`evals/`). Each run found something, and we fixed it:

| Metric | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| answer_correctness | 0.83 | 0.81 | 0.84 |
| propose_never_post (custom judge) | 0.92 | 0.98 | **1.00** |
| currency_correctness (custom judge) | 0.91 | 0.82 | 0.90 |
| logical_consistency | 0.86 | 0.83 | 0.83 |
| tool_execution_accuracy | 0.87 | 0.97 | **0.99** |
| tool_selection_accuracy | 0.59 | 0.79 | 0.86 |

- **Run 1 → 2 (agent instructions).**
  - The agent answered "already accrued" from the data instead of asking the procedure, which is the system of record. It now always calls the procedure.
  - Tables showed amounts without currency codes.
- **Run 2 → 3 (semantic model).** Asked for "total use tax for Q3", the agent said USD 16,137 instead of USD 9,801: the "to accrue" column also counted tax already in the GL. The view now splits use tax into *owed*, *in GL* and *still to accrue* (owed = in GL + to accrue), and the semantic view says never to add them together. The custom currency judge is strict: it also fails a raw number in an auto-generated table, and a "$10,000" quoted from a policy.

## Run it yourself

You need a Snowflake account with Cortex and cross-region inference, plus Python 3.12 with `snowflake-connector-python[pandas]` and `pyyaml`. Create a `~/.snowflake/connections.toml` entry called `hackathon`, then run:

```bash
python run_sql.py sql/00_setup.sql                 # roles, warehouse, database, Claude smoke test
python load.py --connection hackathon --policies   # ERP extract + policy PDFs
python run_sql.py sql/01_core_views.sql            # business views + tie-out checks
python run_sql.py sql/04_tools.sql                 # proposal tables + procedures + grants
python run_sql.py sql/02_search.sql                # AI_PARSE_DOCUMENT -> Cortex Search
python run_sql.py sql/03_semantic_view.sql
python run_sql.py sql/05_agent.sql                 # the agent + smoke tests
python run_sql.py sql/06_mcp.sql                   # MCP server, service user, PAT (shown once)
python run_sql.py sql/07_governance.sql            # row access, masking, guardrails, traces
python load.py --connection hackathon --evals-only && python run_sql.py sql/08_evals.sql
python ask_agent.py "Run the September 2026 supplier-invoice tax close."
python run_sql.py sql/reset_demo.sql               # clear proposals before a demo
```

`RUNBOOK.md` has the expected output for every step, plus pitfalls. `MCP_CLIENTS.md` explains how to connect Claude Code and Claude Desktop.

## Repo layout

| Path | What |
|---|---|
| `sql/` | Numbered setup scripts 00 to 08, plus `reset_demo.sql` |
| `load.py` | Typed loader (PUT/COPY), policy upload and markdown fallback chunks |
| `run_sql.py`, `ask_agent.py` | Script runner; ask the agent from the terminal and see which tools it called |
| `data/` | Synthetic ERP extract (CSV) |
| `policies/` | 7 fictional internal tax policy memos, as markdown and PDF |
| `evals/` | Question set generator (answers computed from the CSVs) and eval config |

## Disclosure

The synthetic Halide Labs dataset comes from an earlier project of mine (myERP) and was copied unchanged. It contains no real company data. Everything on Snowflake was built at the hackathon: loaders, views, semantic view, policy memos, search, procedures, agent, MCP server, governance and evals. The policy memos are fictional demo documents. They describe tax law only in general terms and are not tax advice.
