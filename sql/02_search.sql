-- =====================================================================================
-- 02_search.sql — policy memos -> AI_PARSE_DOCUMENT -> chunks -> Cortex Search service
-- Run AFTER: load.py --policies  (uploads policies/pdf/*.pdf + *.md to @AGENT.POLICY_STAGE
--            AND loads the markdown fallback chunks into AGENT.POLICY_CHUNKS).
-- Role: HALIDE_BUILDER.
-- Docs verified 2026-10-23:
--   https://docs.snowflake.com/en/sql-reference/functions/ai_parse_document
--   https://docs.snowflake.com/en/sql-reference/functions/split_text_recursive_character-snowflake-cortex
--   https://docs.snowflake.com/en/sql-reference/sql/create-cortex-search
--   https://docs.snowflake.com/en/sql-reference/functions/search_preview-snowflake-cortex
-- AI_PARSE_DOCUMENT accepts PDF/DOCX/PPTX/images/HTML/TXT — NOT .md (hence the PDFs).
-- No Snowflake CLI? Upload the PDFs in Snowsight: Catalog » HALIDE_TAX » AGENT » Stages »
--   POLICY_STAGE » + Files.
-- =====================================================================================
USE ROLE HALIDE_BUILDER;
USE WAREHOUSE HALIDE_WH;
USE SCHEMA HALIDE_TAX.AGENT;

CREATE TABLE IF NOT EXISTS HALIDE_TAX.AGENT.POLICY_CHUNKS (
  CHUNK_ID VARCHAR, POLICY_ID VARCHAR, POLICY_TITLE VARCHAR, FILE_NAME VARCHAR,
  CHUNK_INDEX NUMBER, CHUNK VARCHAR, SOURCE_METHOD VARCHAR,
  LOADED_AT TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP());

-- policy catalog (file -> id/title), used to label parsed chunks
CREATE OR REPLACE TABLE HALIDE_TAX.AGENT.POLICY_CATALOG (POLICY_ID VARCHAR, POLICY_TITLE VARCHAR, FILE_NAME VARCHAR);
INSERT INTO HALIDE_TAX.AGENT.POLICY_CATALOG VALUES
 ('HL-TAX-POL-001','Use Tax Accrual Policy','01_use_tax_accrual_policy.pdf'),
 ('HL-TAX-POL-002','Vendor Tax Overcharge and Refund Procedure','02_vendor_overcharge_refund_procedure.pdf'),
 ('HL-TAX-POL-003','EU Reverse-Charge and Acquisition VAT Procedure (Ireland)','03_eu_reverse_charge_procedure.pdf'),
 ('HL-TAX-POL-004','Tax Journal Approval Matrix and Segregation of Duties','04_approval_matrix_sod.pdf'),
 ('HL-TAX-POL-005','Indirect Tax Month-End Close Calendar','05_close_calendar.pdf'),
 ('HL-TAX-POL-006','Vendor Tax Exemption and Registration Certificates','06_exemption_registration_certificates.pdf'),
 ('HL-TAX-POL-007','Tax Records Retention and Audit Trail','07_records_retention_audit_trail.pdf');

-- ---------- PATH A: parse the PDFs with AI_PARSE_DOCUMENT (Document AI) --------------
ALTER STAGE HALIDE_TAX.AGENT.POLICY_STAGE REFRESH;
SELECT RELATIVE_PATH, SIZE FROM DIRECTORY('@HALIDE_TAX.AGENT.POLICY_STAGE');   -- expect 7 .pdf (+ 7 .md)

CREATE OR REPLACE TABLE HALIDE_TAX.AGENT.POLICY_DOCS_PARSED AS
SELECT RELATIVE_PATH AS FILE_NAME,
       -- PARSE_JSON(TO_VARCHAR(..)) works whether the function returns OBJECT or a JSON string
       PARSE_JSON(TO_VARCHAR(
         AI_PARSE_DOCUMENT(TO_FILE('@HALIDE_TAX.AGENT.POLICY_STAGE', RELATIVE_PATH), {'mode': 'LAYOUT'})
       )):content::VARCHAR AS DOC_TEXT
FROM DIRECTORY('@HALIDE_TAX.AGENT.POLICY_STAGE')
WHERE RELATIVE_PATH ILIKE '%.pdf';

-- check: 7 rows, DOC_TEXT not null (NULL = parse failed; AI_PARSE_DOCUMENT fails silently)
SELECT FILE_NAME, LENGTH(DOC_TEXT) AS CHARS, LEFT(DOC_TEXT, 120) AS PREVIEW
FROM HALIDE_TAX.AGENT.POLICY_DOCS_PARSED ORDER BY 1;

-- chunk (~1,500 chars, 200 overlap; docs recommend <=512 tokens per chunk)
DELETE FROM HALIDE_TAX.AGENT.POLICY_CHUNKS WHERE SOURCE_METHOD = 'ai_parse_document';
INSERT INTO HALIDE_TAX.AGENT.POLICY_CHUNKS
  (CHUNK_ID, POLICY_ID, POLICY_TITLE, FILE_NAME, CHUNK_INDEX, CHUNK, SOURCE_METHOD)
SELECT c.POLICY_ID || ':pdf:' || f.INDEX,
       c.POLICY_ID, c.POLICY_TITLE, p.FILE_NAME, f.INDEX,
       '[' || c.POLICY_ID || ' ' || c.POLICY_TITLE || ']' || CHR(10) || f.VALUE::VARCHAR,
       'ai_parse_document'
FROM HALIDE_TAX.AGENT.POLICY_DOCS_PARSED p
JOIN HALIDE_TAX.AGENT.POLICY_CATALOG c ON c.FILE_NAME = p.FILE_NAME,
     LATERAL FLATTEN(INPUT => SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(p.DOC_TEXT, 'markdown', 1500, 200)) f
WHERE p.DOC_TEXT IS NOT NULL;

SELECT SOURCE_METHOD, COUNT(DISTINCT POLICY_ID) AS POLICIES, COUNT(*) AS CHUNKS
FROM HALIDE_TAX.AGENT.POLICY_CHUNKS GROUP BY 1;
-- expect: ai_parse_document 7 policies ~15-25 chunks ; markdown_direct 7 policies ~20 chunks

-- ---------- choose ONE source so search results are not duplicated -------------------
-- If Path A gave all 7 policies -> keep the parsed chunks (Document AI in the story):
DELETE FROM HALIDE_TAX.AGENT.POLICY_CHUNKS WHERE SOURCE_METHOD = 'markdown_direct'
  AND (SELECT COUNT(DISTINCT POLICY_ID) FROM HALIDE_TAX.AGENT.POLICY_CHUNKS
        WHERE SOURCE_METHOD = 'ai_parse_document') = 7;
-- FALLBACK (parsing failed / NULL text): keep markdown_direct and remove partial parses:
-- DELETE FROM HALIDE_TAX.AGENT.POLICY_CHUNKS WHERE SOURCE_METHOD = 'ai_parse_document';
-- (and if markdown_direct rows are missing: uv run ... python load.py --policies-only)

-- ---------- Cortex Search service ----------------------------------------------------
-- Source query must be a plain SELECT on a table (incremental refresh); no AI calls inside.
CREATE OR REPLACE CORTEX SEARCH SERVICE HALIDE_TAX.AGENT.POLICY_SEARCH
  ON CHUNK
  ATTRIBUTES POLICY_ID, POLICY_TITLE
  WAREHOUSE = HALIDE_WH
  TARGET_LAG = '1 hour'
  COMMENT = 'Halide Labs internal tax policies (fictional): use tax, overcharges, reverse charge, approvals, close calendar'
AS (
  SELECT CHUNK_ID, CHUNK, POLICY_ID, POLICY_TITLE, FILE_NAME, SOURCE_METHOD
  FROM HALIDE_TAX.AGENT.POLICY_CHUNKS
);
-- default EMBEDDING_MODEL = snowflake-arctic-embed-m-v1.5 (English, fine here)

DESCRIBE CORTEX SEARCH SERVICE HALIDE_TAX.AGENT.POLICY_SEARCH;   -- check indexing_state / indexing_error

-- test (arguments must be literals)
SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
  'HALIDE_TAX.AGENT.POLICY_SEARCH',
  '{"query": "who can approve a use tax accrual journal and can the AI assistant post it",
    "columns": ["POLICY_ID", "POLICY_TITLE", "CHUNK"], "limit": 3}'
))['results'] AS RESULTS;
-- expect HL-TAX-POL-004 first.

SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
  'HALIDE_TAX.AGENT.POLICY_SEARCH',
  '{"query": "vendor charged sales tax that was not due",
    "columns": ["POLICY_ID", "POLICY_TITLE", "CHUNK"],
    "filter": {"@eq": {"POLICY_ID": "HL-TAX-POL-002"}}, "limit": 2}'
))['results'] AS RESULTS_FILTERED;

-- ---------- grants -------------------------------------------------------------------
GRANT USAGE ON CORTEX SEARCH SERVICE HALIDE_TAX.AGENT.POLICY_SEARCH TO ROLE TAX_AGENT;
-- Cost note: a search service is billed while it exists (serving GB-month). Drop it after
-- judging:  DROP CORTEX SEARCH SERVICE HALIDE_TAX.AGENT.POLICY_SEARCH;
