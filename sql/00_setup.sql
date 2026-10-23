-- =====================================================================================
-- 00_setup.sql — account setup for the Halide Labs use-tax close desk
-- Run in a Snowsight SQL worksheet as ACCOUNTADMIN, top to bottom.
-- Creates: roles, warehouse HALIDE_WH, database HALIDE_TAX (RAW / CORE / AGENT / EVALS),
--          policy stage, Cortex grants, cross-region inference, model smoke test.
-- Docs verified 2026-10-23:
--   cross-region   https://docs.snowflake.com/en/user-guide/snowflake-cortex/cross-region-inference
--   models         https://docs.snowflake.com/en/user-guide/snowflake-cortex/aisql-regional-availability
--   agent grants   https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents-setup
--   db roles       https://docs.snowflake.com/en/sql-reference/snowflake-db-roles
-- =====================================================================================
USE ROLE ACCOUNTADMIN;

-- ---------- 0. cross-region inference (REQUIRED for Claude) --------------------------
-- No Claude model runs natively in North America / APAC regions, so Claude in AI_COMPLETE,
-- Cortex Agents and Cortex Analyst needs cross-region inference. ACCOUNTADMIN only.
SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;   -- read the "value" column
ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';
-- (AWS_US also covers most Claude models on a US AWS account, but claude-sonnet-5-5 is
--  ANY_REGION only, and Azure/GCP accounts need ANY_REGION for any Claude model.)

-- ---------- 1. roles -----------------------------------------------------------------
--   HALIDE_BUILDER : owns every object (tables, views, procs, agent, search, MCP server)
--   TAX_AGENT      : what the AI agent / MCP service user runs as: read + propose + flag
--   TAX_ANALYST    : human tax team = TAX_AGENT + audit log read
--   CONTROLLER     : TAX_ANALYST + approve/reject proposals (only role with that grant)
CREATE ROLE IF NOT EXISTS HALIDE_BUILDER COMMENT = 'Owner of the Halide Labs tax close desk objects';
CREATE ROLE IF NOT EXISTS TAX_AGENT      COMMENT = 'AI tax assistant: read, propose, flag. Never approve or post.';
CREATE ROLE IF NOT EXISTS TAX_ANALYST    COMMENT = 'Tax team: everything TAX_AGENT can do, plus audit log';
CREATE ROLE IF NOT EXISTS CONTROLLER     COMMENT = 'Controller: approves or rejects tax journal proposals';

GRANT ROLE TAX_AGENT      TO ROLE TAX_ANALYST;
GRANT ROLE TAX_ANALYST    TO ROLE CONTROLLER;
GRANT ROLE HALIDE_BUILDER TO ROLE SYSADMIN;      -- admins inherit builder rights
GRANT ROLE CONTROLLER     TO ROLE SYSADMIN;

-- grant the roles to YOU (quoted so names with '@' or lower case work)
SET ME = '"' || CURRENT_USER() || '"';
GRANT ROLE HALIDE_BUILDER TO USER IDENTIFIER($ME);
GRANT ROLE TAX_AGENT      TO USER IDENTIFIER($ME);   -- direct grant so USE ROLE TAX_AGENT works
GRANT ROLE TAX_ANALYST    TO USER IDENTIFIER($ME);
GRANT ROLE CONTROLLER     TO USER IDENTIFIER($ME);

-- ---------- 2. account-level privileges ----------------------------------------------
GRANT CREATE DATABASE  ON ACCOUNT TO ROLE HALIDE_BUILDER;
GRANT CREATE WAREHOUSE ON ACCOUNT TO ROLE HALIDE_BUILDER;
GRANT EXECUTE TASK     ON ACCOUNT TO ROLE HALIDE_BUILDER;   -- needed by Cortex Agent evaluations
-- Cortex AI: USE AI FUNCTIONS + CORTEX_USER are granted to PUBLIC by default; grant explicitly anyway
GRANT USE AI FUNCTIONS ON ACCOUNT TO ROLE HALIDE_BUILDER;
GRANT USE AI FUNCTIONS ON ACCOUNT TO ROLE TAX_AGENT;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER       TO ROLE HALIDE_BUILDER;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER       TO ROLE TAX_AGENT;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_AGENT_USER TO ROLE TAX_AGENT;
-- CoCo inside Snowsight may also need: GRANT DATABASE ROLE SNOWFLAKE.COPILOT_USER TO ROLE <role>;

-- ---------- 3. objects (owned by HALIDE_BUILDER) -------------------------------------
USE ROLE HALIDE_BUILDER;

CREATE WAREHOUSE IF NOT EXISTS HALIDE_WH
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Halide Labs tax close desk (loads, Analyst SQL, agent tools, search refresh)';
USE WAREHOUSE HALIDE_WH;

CREATE DATABASE IF NOT EXISTS HALIDE_TAX COMMENT = 'Halide Labs (fictional) indirect tax close desk';
CREATE SCHEMA IF NOT EXISTS HALIDE_TAX.RAW   COMMENT = 'Synthetic ERP extract, integer minor units, private';
CREATE SCHEMA IF NOT EXISTS HALIDE_TAX.CORE  COMMENT = 'Business views in major units + semantic view';
CREATE SCHEMA IF NOT EXISTS HALIDE_TAX.AGENT COMMENT = 'Agent, tools, proposals, audit log, policy search';
CREATE SCHEMA IF NOT EXISTS HALIDE_TAX.EVALS COMMENT = 'Cortex Agent evaluation datasets and config';

-- stage for policy PDFs (AI_PARSE_DOCUMENT needs server-side encryption + directory table)
CREATE STAGE IF NOT EXISTS HALIDE_TAX.AGENT.POLICY_STAGE
  DIRECTORY = (ENABLE = TRUE) ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Halide Labs internal tax policy memos (fictional)';

-- ---------- 4. usage grants for consumer roles ---------------------------------------
GRANT USAGE ON WAREHOUSE HALIDE_WH         TO ROLE TAX_AGENT;
GRANT USAGE ON DATABASE  HALIDE_TAX        TO ROLE TAX_AGENT;
GRANT USAGE ON SCHEMA    HALIDE_TAX.CORE   TO ROLE TAX_AGENT;
GRANT USAGE ON SCHEMA    HALIDE_TAX.AGENT  TO ROLE TAX_AGENT;
-- RAW is deliberately NOT granted: consumers read CORE views only.

-- ---------- 5. Claude smoke test -----------------------------------------------------
-- Current Claude model ids for AI_COMPLETE (all need cross-region on NA/APAC accounts):
--   GA     : claude-sonnet-4-6 (widest availability), claude-sonnet-5, claude-opus-5,
--            claude-opus-4-8, claude-opus-4-7, claude-opus-4-6, claude-haiku-4-5,
--            claude-sonnet-4-5, claude-opus-4-5
--   preview: claude-opus-5-5 (ANY_REGION/AWS_US/...), claude-sonnet-5-5 (ANY_REGION only)
-- Cortex AGENT orchestration list (GA): claude-opus-5, claude-sonnet-5, claude-opus-4-8,
--   claude-opus-4-7, claude-opus-4-6, claude-sonnet-4-6, claude-haiku-4-5, ... or 'auto'.
--   (opus-5-5 / sonnet-5-5 are NOT in the agent list.)
-- Run as a NON-admin role: ACCOUNTADMIN bypasses model RBAC, so a test as admin can hide problems.
USE ROLE TAX_AGENT;
USE WAREHOUSE HALIDE_WH;
SELECT AI_COMPLETE('claude-sonnet-4-6', 'Reply with exactly: ok') AS sonnet_4_6;
SELECT AI_COMPLETE('claude-sonnet-5',   'Reply with exactly: ok') AS sonnet_5;
SELECT AI_COMPLETE('claude-opus-5',     'Reply with exactly: ok') AS opus_5;
-- fallbacks if one fails:  'claude-haiku-4-5', 'claude-opus-4-6', 'claude-sonnet-4-5'
-- AI_COMPLETE returns NULL on error. If you get NULL: check cross-region (step 0), then
--   USE ROLE ACCOUNTADMIN; CALL SNOWFLAKE.MODELS.CORTEX_BASE_MODELS_REFRESH();
--   SHOW APPLICATION ROLES LIKE 'CORTEX-MODEL%' IN APPLICATION SNOWFLAKE;   -- model RBAC
-- structured-output example (handy for the demo):
SELECT AI_COMPLETE(
  model => 'claude-sonnet-4-6',
  prompt => 'A Texas vendor billed USD 42,000 of software and charged no sales tax. Classify.',
  model_parameters => {'temperature': 0, 'max_tokens': 300},
  response_format => {'type': 'json', 'schema': {'type': 'object',
     'properties': {'issue': {'type': 'string'}, 'who_owes_tax': {'type': 'string'}},
     'required': ['issue', 'who_owes_tax']}}) AS structured_test;

USE ROLE HALIDE_BUILDER;
-- NEXT: run `uv run --with "snowflake-connector-python[pandas]" --with pyyaml python load.py --connection hackathon --policies`
