-- =====================================================================================
-- 05_agent.sql — the Cortex Agent: HALIDE_TAX.AGENT.USE_TAX_CLOSE_DESK (Claude orchestration)
-- Run AFTER 02 (search), 03 (semantic view), 04 (procedures).  Role: HALIDE_BUILDER.
-- Docs verified 2026-10-23:
--   CREATE AGENT  https://docs.snowflake.com/en/sql-reference/sql/create-agent
--   spec/tools    https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents-manage
--   code exec     https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents-code-execution-tool
--   run from SQL  https://docs.snowflake.com/en/sql-reference/functions/data_agent_run-snowflake-cortex
--   CoWork        https://docs.snowflake.com/en/user-guide/snowflake-cortex/snowflake-cowork/deploy-agents
-- The agent runs with the CALLER's roles. A TAX_ANALYST can propose/flag through it; nobody
-- can approve through it (no approve tool, and APPROVE_PROPOSAL is CONTROLLER-only anyway).
-- CREATE AGENT does NOT validate tools: test with DATA_AGENT_RUN below before the demo.
-- Pitfalls: tool_resources keys must equal tool names EXACTLY; warehouse name in CAPS;
--   CREATE OR REPLACE drops grants (we re-grant below) and evaluation history.
-- =====================================================================================
USE ROLE HALIDE_BUILDER;
USE WAREHOUSE HALIDE_WH;
USE SCHEMA HALIDE_TAX.AGENT;

CREATE OR REPLACE AGENT HALIDE_TAX.AGENT.USE_TAX_CLOSE_DESK
  COMMENT = 'Halide Labs use-tax close desk: reviews supplier-invoice tax, proposes (never posts) use tax accruals, flags vendor overcharges, cites internal policy.'
  PROFILE = '{"display_name": "Use-Tax Close Desk", "color": "blue"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: claude-sonnet-5

  orchestration:
    tool_not_accessible: accept

  instructions:
    response: |
      You are the use-tax close desk assistant for Halide Labs, a fictional AI-compute company with
      four entities: US (Halide Labs, USD), IE (Halide Labs Ireland, EUR), JP (Halide Labs Japan, JPY)
      and SG (Halide Labs Asia, SGD). You help the tax team close the month.
      Style: lead with the answer in one or two sentences, then a short table when listing invoices.
      Amounts: always show the currency code with the amount in major units, e.g. "USD 3,465.00",
      "EUR 4,140.00", "JPY 22,000" (JPY has no decimals). Never add amounts in different currencies.
      In tables, put the currency code in every amount cell or include a Currency column.
      Never use the "$" sign: write the ISO code ("USD 10,000"), also when quoting policy thresholds.
      When a tool result names a GL entry (e.g. US-RE-2026-000008) or a proposal/flag ID, quote it.
      Always name the document number(s) and supplier.
      When you rely on a policy, cite it by ID and title, e.g. "per HL-TAX-POL-001 Use Tax Accrual Policy".
      Writes: you can only PROPOSE journal entries and FLAG overcharges. A proposal is "pending Controller
      approval". Never say an entry was posted, booked, approved or recorded in the ledger. If a user asks
      you to approve or post, say that only a Controller can approve (HL-TAX-POL-004) and the ERP posts
      approved entries; tell them the proposal ID to approve.
      If a tool returns already_proposed, already_in_gl, already_flagged or not_applicable, say so plainly.
      Do not give tax-law advice beyond what the policies and data say; Halide Labs data is synthetic.
    orchestration: |
      Use tax_data (Cortex Analyst) for any question about invoices, amounts, periods, tax lines,
      the GL, rates in the data, or proposal status. Use policy_search for what the internal policy
      or procedure says (who approves, thresholds, steps, deadlines, accounting entries).
      For "what should we do" questions, use both: data first, then policy.
      Call propose_use_tax_accrual for supplier invoices whose CLOSE_ACTION is ACCRUE_USE_TAX.
      When the user names a specific invoice and asks to propose/accrue it, ALWAYS call
      propose_use_tax_accrual for it, even if the data suggests it is already accrued: the procedure
      is the system of record and safely returns already_in_gl / already_proposed / not_applicable
      with the GL entry or proposal ID. Pass the bare document number with no quotes
      (SINV-US-2026-000012). One call per invoice. Never invent amounts: the procedure computes them
      from the tax engine lines.
      "Run the close" / "work the close" for a period means: (1) list the supplier invoices with
      CLOSE_ACTION ACCRUE_USE_TAX or VENDOR_OVERCHARGE for that period, (2) propose each accrual,
      (3) flag each overcharge, (4) finish with a short close summary table (document, supplier,
      action taken, amount with currency, proposal/flag ID, next step) and who must approve per
      HL-TAX-POL-004.
      Call flag_vendor_overcharge only for invoices with an overcharge (CLOSE_ACTION VENDOR_OVERCHARGE),
      with a one-sentence note explaining why.
      Before proposing or flagging in bulk, list the invoices and amounts you are about to act on.
      Use data_to_chart only when the user asks for a chart or trend.
    sample_questions:
      - question: "What does the September 2026 supplier-invoice tax close look like?"
      - question: "Run the September 2026 supplier-invoice tax close."
      - question: "Which supplier invoices need use tax accrued in September 2026, and how much?"
      - question: "Where did a vendor overcharge us on tax, and what does our policy say to do?"
      - question: "Propose the use tax accrual for SINV-US-2026-000012."
      - question: "Who has to approve a use tax accrual, and can you post it?"

  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "tax_data"
        description: "Text-to-SQL over the Halide Labs tax close semantic view: supplier invoices with their tax outcome and CLOSE_ACTION (ACCRUE_USE_TAX, USE_TAX_ACCRUED, VENDOR_OVERCHARGE, SELF_ASSESSED_VAT_IN_GL, VENDOR_TAX_OK, NO_TAX_DUE), tax engine lines (rates, jurisdictions, rule IDs, treatments), posted GL lines (accounts 2410 use tax payable, 2420 self-assessed VAT), journal proposals and their approval status, entities and vendors. Amounts are in invoice currency, major units."
    - tool_spec:
        type: "cortex_search"
        name: "policy_search"
        description: "Searches Halide Labs internal tax policies (HL-TAX-POL-001 to 007): use tax accrual, vendor overcharge and refund procedure, EU reverse charge and acquisition VAT, approval matrix and segregation of duties, close calendar, exemption and registration certificates, records retention. Returns policy text with policy ID and title. Not for numbers."
    - tool_spec:
        type: "generic"
        name: "propose_use_tax_accrual"
        description: "Creates a PENDING (not posted) use tax accrual journal proposal for ONE supplier invoice. The amount is computed deterministically from the tax engine lines (treatment use_tax_accrual): debit the purchase expense account, credit 2410 US use tax payable. Idempotent: returns already_proposed or already_in_gl instead of creating duplicates. Returns JSON with proposal_id, amount_display, journal lines and next_step."
        input_schema:
          type: "object"
          properties:
            DOCUMENT_NUMBER:
              type: "string"
              description: "Supplier invoice number exactly as in the data, e.g. SINV-US-2026-000012"
          required: ["DOCUMENT_NUMBER"]
    - tool_spec:
        type: "generic"
        name: "flag_vendor_overcharge"
        description: "Records a vendor tax overcharge flag (credit memo / refund request) for ONE supplier invoice where the vendor charged tax that was not due. Computes the overcharge from the tax engine lines. Does not change the invoice, hold, payment or ledger. Idempotent while a flag is open."
        input_schema:
          type: "object"
          properties:
            DOCUMENT_NUMBER:
              type: "string"
              description: "Supplier invoice number, e.g. SINV-US-2026-000013"
            NOTE:
              type: "string"
              description: "One-sentence reason for the flag, for the AP team"
          required: ["DOCUMENT_NUMBER", "NOTE"]
    - tool_spec:
        type: "data_to_chart"
        name: "data_to_chart"
        description: "Generates a chart from data returned by tax_data."

  tool_resources:
    tax_data:
      semantic_view: "HALIDE_TAX.CORE.TAX_CLOSE_SV"
      execution_environment:
        type: "warehouse"
        warehouse: "HALIDE_WH"
        query_timeout: 120
    policy_search:
      search_service: "HALIDE_TAX.AGENT.POLICY_SEARCH"
      max_results: "4"
      title_column: "POLICY_TITLE"
      id_column: "CHUNK_ID"
    propose_use_tax_accrual:
      type: "procedure"
      identifier: "HALIDE_TAX.AGENT.PROPOSE_USE_TAX_ACCRUAL"
      execution_environment:
        type: "warehouse"
        warehouse: "HALIDE_WH"
        query_timeout: 60
    flag_vendor_overcharge:
      type: "procedure"
      identifier: "HALIDE_TAX.AGENT.FLAG_VENDOR_OVERCHARGE"
      execution_environment:
        type: "warehouse"
        warehouse: "HALIDE_WH"
        query_timeout: 60
  $$;
-- VERIFY: generic-tool resource keys (type: "procedure", identifier, execution_environment) come
--   from Snowflake's custom-tools guide; the reference page only shows type "function".
--   If the procedure tools don't fire: Snowsight » AI & ML » Agents » USE_TAX_CLOSE_DESK » Edit »
--   Tools » Custom tools » + Add » pick the procedure (the UI writes the exact spec), then
--   compare with:  DESCRIBE AGENT HALIDE_TAX.AGENT.USE_TAX_CLOSE_DESK;
-- Model fallbacks if claude-sonnet-5 errors: claude-sonnet-4-6 (widest availability),
--   claude-opus-5, or `auto`.

-- ---------- OPTIONAL: code execution tool (sandboxed Python for charts/calcs) ---------
-- GA Oct 2026. Sandbox cannot query your data; it works on what the agent passes it.
-- To add it, put these under tools: / tool_resources: in the spec above and re-run:
--    - tool_spec:
--        type: "code_execution"
--        name: "code_execution"
--  and
--    code_execution:
--      permission_policy:
--        type: "always_ask"      # SQL DATA_AGENT_RUN and evals cannot approve; use always_allow there
-- (code_execution and code_toolset_all cannot be combined.)

-- ---------- grants -------------------------------------------------------------------
GRANT USAGE ON AGENT HALIDE_TAX.AGENT.USE_TAX_CLOSE_DESK TO ROLE TAX_AGENT;   -- inherited by TAX_ANALYST, CONTROLLER

-- ---------- smoke tests (non-streaming SQL run of the agent) -------------------------
USE ROLE TAX_ANALYST;
SELECT TRY_PARSE_JSON(SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
  'HALIDE_TAX.AGENT.USE_TAX_CLOSE_DESK',
  $${"messages":[{"role":"user","content":[{"type":"text","text":"Which supplier invoices need use tax accrued in September 2026, and how much?"}]}]}$$
)) AS RESP;
-- Inspect RESP:content (thinking / tool_use / tool_result / text) and RESP:warnings
-- (warning 399569 = a tool was not accessible to the caller's role).
-- Expected: SINV-US-2026-000012, Stackworks, USD 3,465.00 (Austin, Texas, 8.25%).

SELECT TRY_PARSE_JSON(SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
  'HALIDE_TAX.AGENT.USE_TAX_CLOSE_DESK',
  $${"messages":[{"role":"user","content":[{"type":"text","text":"Who must approve a use tax accrual, and are you allowed to post it?"}]}]}$$
)) AS RESP_POLICY;

-- flatten to just the final text:
SELECT c.value:text::VARCHAR AS ANSWER
FROM (SELECT TRY_PARSE_JSON(SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
        'HALIDE_TAX.AGENT.USE_TAX_CLOSE_DESK',
        $${"messages":[{"role":"user","content":[{"type":"text","text":"Where did a vendor overcharge us on tax?"}]}]}$$)) AS R),
     LATERAL FLATTEN(INPUT => R:content) c
WHERE c.value:type::VARCHAR = 'text';

-- ---------- CoWork (formerly Snowflake Intelligence) visibility ----------------------
-- If NO CoWork object exists in the account, users see every agent they have USAGE on: done.
-- If one exists, the agent must be added to it (ACCOUNTADMIN):
USE ROLE ACCOUNTADMIN;
SHOW SNOWFLAKE INTELLIGENCES;
-- only if the SHOW returned a row (use its name):
-- ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT ADD AGENT HALIDE_TAX.AGENT.USE_TAX_CLOSE_DESK;
-- CoWork runs with your DEFAULT role + DEFAULT warehouse. For the demo, run as TAX_ANALYST:
SET ME = '"' || CURRENT_USER() || '"';
ALTER USER IDENTIFIER($ME) SET DEFAULT_ROLE = 'TAX_ANALYST' DEFAULT_WAREHOUSE = 'HALIDE_WH';
-- Open https://ai.snowflake.com (CoWork) and pick "Use-Tax Close Desk".
-- Observability: Snowsight » AI & ML » Agents » USE_TAX_CLOSE_DESK » Monitoring (threads, traces,
-- tool calls). SQL version in 07_governance.sql.
