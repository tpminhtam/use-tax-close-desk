# Use-Tax Close Desk: a governed Claude agent for the indirect-tax month-end close

**Team:** Tam Tran (solo) · **Built with:** Snowflake Cortex Agents, Cortex Analyst, Cortex Search, AI_PARSE_DOCUMENT, Snowflake-managed MCP server, Claude (Sonnet 5 orchestration, Sonnet 4.6 in AI functions)

## The problem

Every month a tax team has to check every supplier invoice and answer one question: **did the vendor charge the right tax?**

- If a vendor charged **no** sales tax on a taxable purchase, the buyer owes **use tax**. It has to be self-assessed, accrued and remitted.
- If a vendor charged tax that **wasn't due**, the company is overpaying. The tax has to be held and recovered from the vendor.
- Abroad the same review covers reverse-charge and acquisition VAT, plus qualified-invoice rules.

The work today is recurring, multi-step and spreadsheet-driven:

1. pull invoices and tax determinations;
2. find the exceptions;
3. look up the internal policy;
4. write journal entries;
5. get a controller's approval.

Mistakes either leave a liability unrecorded or leak cash. Because the work touches the general ledger, any automation has to respect **segregation of duties**: whoever prepares an entry must not approve it.

## What we built

**Halide Labs** is a fictional AI-compute company with 4 entities: US, Ireland, Japan and Singapore. Its **use-tax close desk** is a Cortex Agent running on Claude, which a business user can question in plain English in **CoWork**. The same agent is reachable from **Claude Code / Claude Desktop** through the **Snowflake-managed MCP server**.

- **Ask:** *"What does the September close look like?"* The agent returns a worklist from a semantic view over the ERP extract: 1 invoice needs USD 3,465.00 of use tax accrued, 1 vendor overcharged USD 103,500.00, and 26 need nothing new.
- **Explain:** *"What does our policy say?"* Cortex Search retrieves the internal policy memos, which were parsed from PDF with AI_PARSE_DOCUMENT and chunked. The agent cites them by ID, e.g. HL-TAX-POL-002.
- **Act, safely:** *"Propose the accrual."* The agent calls a stored procedure that **computes the amount deterministically** from the tax-engine lines and writes a balanced journal **proposal** with status *pending*: Dr expense / Cr 2410 US use tax payable. A second tool flags vendor overcharges for a credit memo. Both tools are idempotent.
- **Approve:** only the **CONTROLLER** role can execute `APPROVE_PROPOSAL`. The procedure also blocks self-approval (maker-checker) and checks that the entry balances. Approved proposals go to an ERP hand-off view. **Nothing is ever posted by the agent.**

## How it uses Snowflake + Claude (the five dimensions)

| Dimension | What we used |
|---|---|
| **Surface** | CoWork for business users; Claude Code via MCP for builders; Snowsight for the Controller |
| **Context** | Typed RAW tables loaded via `PUT`/`COPY`; CORE views that convert integer minor units to major units per currency (JPY exponent 0); a **semantic view** with synonyms ("use tax", "overcharge", "reverse charge"), metric definitions, SQL-generation instructions ("never add across currencies") and verified queries |
| **Toolkit** | Cortex Analyst (text-to-SQL on the semantic view), Cortex Search (policies), AI_PARSE_DOCUMENT + SPLIT_TEXT_RECURSIVE_CHARACTER, custom tools = stored procedures, data_to_chart |
| **Intelligence** | Claude as the agent's orchestration model via cross-region inference; AI_COMPLETE with structured outputs for classification tests |
| **Action** | Owner's-rights stored procedures as governed write-back; the Snowflake-managed MCP server exposing the agent, Analyst, Search and the two procedures, with no raw-SQL tool |
| **Observability** | Agent monitoring traces (`GET_AI_OBSERVABILITY_EVENTS`) plus our own append-only `AUDIT_LOG`, which records who, which role, what, the outcome and the policy cited |
| **Evals** | Cortex Agent evaluations on 12 questions whose expected answers are **computed by a script from the source data**. Built-in metrics are answer correctness, logical consistency, tool selection and tool execution. Custom LLM judges are *propose-never-post* and *currency correctness* |
| **Identity / Auth** | Role hierarchy TAX_AGENT ⊂ TAX_ANALYST ⊂ CONTROLLER; a service user with a role-restricted PAT for MCP; an OAuth public client for Claude.ai |
| **Governance** | SoD enforced by grants, not prompts. A row access policy by entity (a Japan analyst sees only JP). A masking policy on tax registration numbers. Cortex AI Guardrails for prompt injection |

## Controls (why a controller could trust it)

1. **The model never decides the number.** Amounts come from the tax engine's lines through a deterministic procedure. Claude decides *what to do* and explains it.
2. **The agent can't write directly.** No role has INSERT or UPDATE on the proposal tables. The only write path is the procedures. They run with owner's rights, hard-code `status = 'pending'`, build balanced entries and log every call.
3. **The agent can't approve or post.** The approve procedure is granted only to CONTROLLER. Maker-checker is enforced in SQL, and no posting path exists.
4. **The same rules apply on every surface.** CoWork, Snowsight, Claude Code over MCP and SQL all go through the same roles, policies and procedures.

## Results

- **Data checks:** the worklist ties out to the source (28 supplier invoices), every GL entry balances, and JPY amounts render without decimals.
- **Evals (3 runs, 12 questions each):** in run 3, propose-never-post scored 1.00, tool execution 0.99, currency correctness 0.90, tool selection 0.86 and answer correctness 0.84. Each run caught a bug that we then fixed; details are in the README.

## What's next

- Run it on the live AP feed.
- Schedule the review as a month-end CoWork automation.
- Add vendor exemption-certificate checks.
- Extend the rule sets (more US states, JP qualified-invoice credit limits, SG reverse charge).
- Post approved proposals back to the ERP through the same governed-tool pattern.
- Measure the close-time saved per period.

## Disclosure

The synthetic dataset comes from Tam's own earlier project **myERP**: the Halide Labs entities, vendors, invoices, tax-engine lines, journal entries and rate content. It is copied, not modified. It contains no real company data.

**Everything on Snowflake was built today at the hackathon:** schemas, loaders, views, semantic view, policy memos, search service, procedures, agent, MCP server, governance policies and evals.

The internal policy memos are fictional demo documents. They state tax law only in general terms and are not tax advice.
