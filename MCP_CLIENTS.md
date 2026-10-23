# Connect Claude to the Halide Labs close desk (Snowflake-managed MCP server)

Prereq: `sql/06_mcp.sql` has run. You have:

- **MCP_URL**, printed by 06 step 3. It looks like
  `https://<org>-<account>.snowflakecomputing.com/api/v2/databases/HALIDE_TAX/schemas/AGENT/mcp-servers/TAX_DESK_MCP`.
  The host name uses hyphens, never underscores.
- **PAT**: the `token_secret` from `ALTER USER HALIDE_AGENT_SVC ADD PROGRAMMATIC ACCESS TOKEN ...`. It is shown once.
- **OAuth client id**: `oauth_client_id` from `SELECT SYSTEM$SHOW_OAUTH_CLIENT_SECRETS('HALIDE_CLAUDE_OAUTH')`. This is only needed for Claude.ai or Desktop.

The server exposes 5 tools:

| Tool | What it does |
|---|---|
| `use_tax_close_desk` | The whole Cortex Agent: Claude plus Analyst, Search and the procedures |
| `tax_close_data` | Cortex Analyst on the semantic view |
| `tax_policy_search` | Cortex Search over the policy memos |
| `propose_use_tax_accrual` | Owner's-rights procedure. Creates a pending proposal only |
| `flag_vendor_overcharge` | Owner's-rights procedure |

There is no raw-SQL tool and no approve tool.

## 1. Claude Code (PAT bearer header, the fastest route)

```bash
export MCP_URL='https://<org>-<account>.snowflakecomputing.com/api/v2/databases/HALIDE_TAX/schemas/AGENT/mcp-servers/TAX_DESK_MCP'
export SF_PAT='<token_secret>'

# sanity check first (expects a JSON or SSE response listing 5 tools)
curl -s -X POST "$MCP_URL" -H "Authorization: Bearer $SF_PAT" \
  -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | head -c 1500

# register with Claude Code (project scope so it lives in this folder)
claude mcp add --transport http halide-tax "$MCP_URL" \
  --header "Authorization: Bearer $SF_PAT"
claude mcp list            # should show halide-tax ✓ connected
```

In Claude Code, `/mcp` shows the tools. Try these prompts:

- "Use the halide-tax tools: which supplier invoices need use tax accrued in September 2026? Propose the accrual."
- "Ask the close desk agent where a vendor overcharged us, then flag it."

The proposal is recorded with `PROPOSED_BY_USER = HALIDE_AGENT_SVC`. Then, in Snowsight as yourself:

```sql
USE ROLE CONTROLLER;
CALL HALIDE_TAX.AGENT.APPROVE_PROPOSAL('PJ-00001');
```

This is maker-checker across two identities, enforced by Snowflake.

### Gotchas

- A 401 or `invalid_client` error usually means the network policy is blocking. Check `HALIDE_MCP_NP` (06 step 3).
- If the `Authorization` header is rejected, Claude Code does **not** fall back to OAuth. Fix the token.
- Agent responses can be 200 KB or more. The agent's search tool is capped at 4 results to help.
- To remove the server: `claude mcp remove halide-tax`.

## 2. Claude.ai / Claude Desktop custom connector (OAuth, PUBLIC client)

Snowflake does not support dynamic client registration, so use your own OAuth client.

1. Make sure your Snowflake user's **DEFAULT_ROLE is TAX_ANALYST** and DEFAULT_WAREHOUSE is HALIDE_WH. `05_agent.sql` sets both. ACCOUNTADMIN and SECURITYADMIN are blocked from OAuth sign-in by default.
2. In claude.ai, go to **Customize → Connectors → + Add → Add custom connector**. Older docs call this "Settings → Connectors".
   - **Name:** `Halide Tax Close Desk`
   - **URL:** your MCP_URL
   - **OAuth client:** "Use your own OAuth client". Paste the `oauth_client_id`.
   - **Client secret:** leave it blank first, because this is a PUBLIC client with PKCE. If sign-in fails, paste `oauth_client_secret` from the same SYSTEM$ call.
3. Click Connect. A Snowflake login appears; sign in as yourself. The redirect goes to `https://claude.ai/api/mcp/auth_callback`, which the integration allows.
4. Claude Desktop uses the same connector as claude.ai. It syncs, and its OAuth also goes through Claude's servers.

Claude requests `session:role:all`, so the session runs as your DEFAULT_ROLE (TAX_ANALYST). The consent screen may say "secondary roles = ALL", but that label is cosmetic because the integration sets `OAUTH_USE_SECONDARY_ROLES = NONE`.

## 3. CoCo (Snowflake's own CLI or Desktop) — optional

CoCo reads `.claude/` project folders and supports MCP servers. You can add the same URL and bearer header in CoCo's MCP settings. See https://docs.snowflake.com/en/user-guide/cortex-code/cortex-code-mcp

## Why this is governed

- The PAT is restricted to `TAX_AGENT`, so Claude Code can read, propose and flag. It cannot approve, because `APPROVE_PROPOSAL` is granted only to CONTROLLER. It cannot post, because no posting path exists. It cannot run raw SQL, because no SYSTEM_EXECUTE_SQL tool is exposed.
- `SYS_CONTEXT('SNOWFLAKE$CURRENT','IS_AGENT_ACTIVATED')` is TRUE for MCP sessions, and `07_governance.sql` masks registration numbers when it is.
- Every call lands in `AGENT.AUDIT_LOG` and in agent monitoring (traces).
