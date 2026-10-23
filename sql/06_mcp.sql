-- =====================================================================================
-- 06_mcp.sql — expose the close desk to Claude Code / Claude Desktop / Claude.ai through the
--              Snowflake-managed MCP server (governed: same roles, same procedures).
-- Run AFTER 05_agent.sql.  Steps 1-2 as HALIDE_BUILDER, steps 3-5 as ACCOUNTADMIN.
-- Docs verified 2026-10-23:
--   https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents-mcp
--   https://docs.snowflake.com/en/sql-reference/sql/create-mcp-server
--   https://docs.snowflake.com/en/user-guide/programmatic-access-tokens
-- Endpoint: https://<org>-<account>.snowflakecomputing.com/api/v2/databases/HALIDE_TAX/schemas/AGENT/mcp-servers/TAX_DESK_MCP
--   (use HYPHENS instead of underscores in the host name)
-- Design choice: NO SYSTEM_EXECUTE_SQL tool on this server — raw SQL would bypass the agent's
-- governance. Writes only through the two owner's-rights procedures (see 04_tools.sql).
-- =====================================================================================
USE ROLE HALIDE_BUILDER;
USE WAREHOUSE HALIDE_WH;

-- ---------- 1. the MCP server --------------------------------------------------------
CREATE OR REPLACE MCP SERVER HALIDE_TAX.AGENT.TAX_DESK_MCP
  FROM SPECIFICATION $$
  tools:
    - title: "Halide Labs use-tax close desk agent"
      name: "use_tax_close_desk"
      type: "CORTEX_AGENT_RUN"
      identifier: "HALIDE_TAX.AGENT.USE_TAX_CLOSE_DESK"
      description: "Ask the Halide Labs tax close desk agent anything about supplier-invoice tax, use tax accruals, vendor overcharges, EU reverse charge, journal proposals and internal tax policy. It can propose (never post) use tax accruals and flag vendor overcharges."
      annotations:
        openWorldHint: false
    - title: "Tax close data (Cortex Analyst)"
      name: "tax_close_data"
      type: "CORTEX_ANALYST_MESSAGE"
      identifier: "HALIDE_TAX.CORE.TAX_CLOSE_SV"
      description: "Natural-language questions over the Halide Labs tax close semantic view (supplier invoices, tax lines, GL, proposals). Returns SQL and results."
    - title: "Tax policy search"
      name: "tax_policy_search"
      type: "CORTEX_SEARCH_SERVICE_QUERY"
      identifier: "HALIDE_TAX.AGENT.POLICY_SEARCH"
      description: "Search Halide Labs internal tax policies HL-TAX-POL-001..007."
    - title: "Propose use tax accrual"
      name: "propose_use_tax_accrual"
      type: "GENERIC"
      identifier: "HALIDE_TAX.AGENT.PROPOSE_USE_TAX_ACCRUAL"
      description: "Create a PENDING (not posted) use tax accrual proposal for one supplier invoice; amount computed from tax engine lines; idempotent."
      annotations:
        readOnlyHint: false
        destructiveHint: false
        idempotentHint: true
        openWorldHint: false
      config:
        type: "procedure"
        warehouse: "HALIDE_WH"
        query_timeout: 60
        input_schema:
          type: "object"
          properties:
            DOCUMENT_NUMBER:
              type: "string"
              description: "Supplier invoice number, e.g. SINV-US-2026-000012"
          required: ["DOCUMENT_NUMBER"]
    - title: "Flag vendor tax overcharge"
      name: "flag_vendor_overcharge"
      type: "GENERIC"
      identifier: "HALIDE_TAX.AGENT.FLAG_VENDOR_OVERCHARGE"
      description: "Record a vendor tax overcharge flag (credit memo / refund request) for one supplier invoice; idempotent while open."
      annotations:
        readOnlyHint: false
        destructiveHint: false
        idempotentHint: true
        openWorldHint: false
      config:
        type: "procedure"
        warehouse: "HALIDE_WH"
        query_timeout: 60
        input_schema:
          type: "object"
          properties:
            DOCUMENT_NUMBER:
              type: "string"
              description: "Supplier invoice number, e.g. SINV-US-2026-000013"
            NOTE:
              type: "string"
              description: "One-sentence reason for the flag"
          required: ["DOCUMENT_NUMBER", "NOTE"]
  $$;
-- VERIFY: `required` inside a GENERIC tool's input_schema is not shown in the MCP doc example
--   (only properties). If CREATE errors, delete the two `required:` lines.

SHOW MCP SERVERS IN SCHEMA HALIDE_TAX.AGENT;
DESCRIBE MCP SERVER HALIDE_TAX.AGENT.TAX_DESK_MCP;

-- ---------- 2. grants: access to the server does NOT grant access to its tools --------
GRANT USAGE ON MCP SERVER HALIDE_TAX.AGENT.TAX_DESK_MCP TO ROLE TAX_AGENT;
-- tools (already granted in 02-05, repeated here so this file stands alone):
GRANT USAGE  ON AGENT HALIDE_TAX.AGENT.USE_TAX_CLOSE_DESK                         TO ROLE TAX_AGENT;
GRANT SELECT ON SEMANTIC VIEW HALIDE_TAX.CORE.TAX_CLOSE_SV                         TO ROLE TAX_AGENT;
GRANT USAGE  ON CORTEX SEARCH SERVICE HALIDE_TAX.AGENT.POLICY_SEARCH              TO ROLE TAX_AGENT;
GRANT USAGE  ON PROCEDURE HALIDE_TAX.AGENT.PROPOSE_USE_TAX_ACCRUAL(VARCHAR)       TO ROLE TAX_AGENT;
GRANT USAGE  ON PROCEDURE HALIDE_TAX.AGENT.FLAG_VENDOR_OVERCHARGE(VARCHAR, VARCHAR) TO ROLE TAX_AGENT;

-- ---------- 3. service user for Claude Code (PAT, role-restricted to TAX_AGENT) -------
-- Proposals made through MCP are then "prepared by" HALIDE_AGENT_SVC, so YOU (CONTROLLER) can
-- approve them without tripping maker-checker — the real SoD story for the demo.
USE ROLE ACCOUNTADMIN;
CREATE USER IF NOT EXISTS HALIDE_AGENT_SVC
  TYPE = SERVICE
  DEFAULT_ROLE = TAX_AGENT
  DEFAULT_WAREHOUSE = HALIDE_WH
  COMMENT = 'Halide Labs AI tax assistant (MCP / Claude Code). TAX_AGENT only: read, propose, flag.';
GRANT ROLE TAX_AGENT TO USER HALIDE_AGENT_SVC;

-- A SERVICE user must be subject to a network policy to use a PAT.
-- Hackathon shortcut: allow all IPs for THIS user only. Better: put your laptop IP
-- (curl -s ifconfig.me) instead of 0.0.0.0/0.
CREATE NETWORK POLICY IF NOT EXISTS HALIDE_MCP_NP
  ALLOWED_IP_LIST = ('0.0.0.0/0')
  COMMENT = 'Hackathon: network policy required for the MCP service user PAT. Tighten after the event.';
ALTER USER HALIDE_AGENT_SVC SET NETWORK_POLICY = HALIDE_MCP_NP;

-- ⚠ COPY token_secret FROM THE RESULT NOW — it is shown only once.
ALTER USER HALIDE_AGENT_SVC ADD PROGRAMMATIC ACCESS TOKEN HALIDE_MCP_PAT
  ROLE_RESTRICTION = 'TAX_AGENT'
  DAYS_TO_EXPIRY = 7
  COMMENT = 'Claude Code MCP connection to TAX_DESK_MCP';
-- Lost it?  ALTER USER HALIDE_AGENT_SVC REMOVE PROGRAMMATIC ACCESS TOKEN HALIDE_MCP_PAT;  then re-add.
-- Alternative (no service user): a PAT for yourself, bypassing the network-policy requirement 24h:
--   ALTER USER ADD PAT my_mcp_pat ROLE_RESTRICTION = 'TAX_ANALYST' DAYS_TO_EXPIRY = 2
--     MINS_TO_BYPASS_NETWORK_POLICY_REQUIREMENT = 1440;

-- your account URL for the endpoint:
SELECT LOWER(CURRENT_ORGANIZATION_NAME() || '-' || REPLACE(CURRENT_ACCOUNT_NAME(), '_', '-'))
       || '.snowflakecomputing.com' AS ACCOUNT_HOST,
       'https://' || LOWER(CURRENT_ORGANIZATION_NAME() || '-' || REPLACE(CURRENT_ACCOUNT_NAME(), '_', '-'))
       || '.snowflakecomputing.com/api/v2/databases/HALIDE_TAX/schemas/AGENT/mcp-servers/TAX_DESK_MCP' AS MCP_URL;

-- ---------- 4. OAuth for Claude.ai / Claude Desktop custom connector (PUBLIC client + PKCE) ---
-- ACCOUNTADMIN / SECURITYADMIN / ORGADMIN cannot sign in via OAuth: your DEFAULT_ROLE must be
-- TAX_ANALYST (set in 05_agent.sql) and you need a DEFAULT_WAREHOUSE.
CREATE OR REPLACE SECURITY INTEGRATION HALIDE_CLAUDE_OAUTH
  TYPE = OAUTH
  OAUTH_CLIENT = CUSTOM
  ENABLED = TRUE
  OAUTH_CLIENT_TYPE = 'PUBLIC'
  OAUTH_REDIRECT_URI = 'https://claude.ai/api/mcp/auth_callback'
  OAUTH_USE_SECONDARY_ROLES = NONE
  ALLOWED_ROLES_LIST = ('TAX_ANALYST', 'TAX_AGENT');
SELECT SYSTEM$SHOW_OAUTH_CLIENT_SECRETS('HALIDE_CLAUDE_OAUTH');   -- copy oauth_client_id (name must be UPPERCASE)

-- ---------- 5. quick server test from a terminal (Claude Code not needed) -------------
-- curl -s -X POST "$MCP_URL" -H "Authorization: Bearer $PAT" \
--   -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
--   -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
-- Error `invalid_client` / 401 often = network policy blocking, not a bad token.
USE ROLE HALIDE_BUILDER;
