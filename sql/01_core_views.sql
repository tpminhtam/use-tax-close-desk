-- =====================================================================================
-- 01_core_views.sql  —  business-friendly views in MAJOR units over HALIDE_TAX.RAW
-- Run AFTER: 00_setup.sql and `load.py`.   Role: HALIDE_BUILDER.
-- RAW amounts are integer MINOR units. Exponents (from myERP myerp/core/money.py):
--   USD 2, EUR 2, SGD 2, GBP 2, JPY 0.  JPY 22000 minor = JPY 22,000 (not 220.00).
-- Sign convention in GL: debit = positive, credit = negative (myERP export).
-- =====================================================================================
USE ROLE HALIDE_BUILDER;
USE WAREHOUSE HALIDE_WH;
USE SCHEMA HALIDE_TAX.CORE;

-- ---------- currency exponents -------------------------------------------------------
CREATE OR REPLACE TABLE HALIDE_TAX.CORE.CURRENCIES (
  CURRENCY        VARCHAR(3) PRIMARY KEY,
  EXPONENT        NUMBER(1,0),
  MINOR_PER_MAJOR NUMBER(10,0)
) COMMENT = 'ISO currency exponents used to convert minor units to major units';
INSERT INTO HALIDE_TAX.CORE.CURRENCIES VALUES
  ('USD',2,100),('EUR',2,100),('GBP',2,100),('SGD',2,100),('AUD',2,100),
  ('INR',2,100),('CHF',2,100),('CAD',2,100),('JPY',0,1);

-- ---------- entities -----------------------------------------------------------------
CREATE OR REPLACE VIEW HALIDE_TAX.CORE.ENTITIES
  COMMENT = 'Halide Labs legal entities (US parent, Ireland, Japan, Singapore)'
AS
SELECT ID AS ENTITY_ID, NAME AS ENTITY_NAME, LEGAL_NAME, COUNTRY AS ENTITY_COUNTRY,
       ENTITY_CURRENCY, GROUP_CURRENCY, ROLE AS ENTITY_ROLE
FROM HALIDE_TAX.RAW.ENTITIES;

-- ---------- suppliers ----------------------------------------------------------------
CREATE OR REPLACE VIEW HALIDE_TAX.CORE.SUPPLIERS
  COMMENT = 'Vendors / suppliers of Halide Labs'
AS
SELECT ID AS SUPPLIER_ID, NAME AS SUPPLIER_NAME, COUNTRY AS SUPPLIER_COUNTRY,
       INDUSTRY AS SUPPLIER_INDUSTRY
FROM HALIDE_TAX.RAW.PARTIES
WHERE ROLES ILIKE '%supplier%';

-- ---------- tax lines (one row per tax determination line) ----------------------------
CREATE OR REPLACE VIEW HALIDE_TAX.CORE.TAX_LINES
  COMMENT = 'Tax determination lines for every invoice, in major units. treatment tells what happened: use_tax_accrual = buyer must self-assess use tax; overcharged = vendor charged tax that was not due; vendor_charged = vendor correctly charged tax; reverse_charge / acquisition_vat = buyer self-assesses VAT.'
AS
SELECT
  t.DOCUMENT_NUMBER,
  t.LINE_REF,
  d.DOC_TYPE,
  d.ENTITY_ID,
  d.ENTITY_NAME,
  d.PARTY                                              AS COUNTERPARTY_NAME,
  d.CURRENCY,
  d.DOCUMENT_DATE,
  TO_CHAR(d.DOCUMENT_DATE, 'YYYY-MM')                  AS CLOSE_PERIOD,
  t.REGIME,
  t.JURISDICTION_CODE,
  t.JURISDICTION_NAME,
  t.LEVEL                                              AS JURISDICTION_LEVEL,
  t.TAX_TYPE,
  t.TREATMENT,
  t.RULE_ID,
  t.MATCH_LEVEL,
  t.RATE,
  t.ACCRUAL                                            AS IS_SELF_ASSESSED,
  t.TAXABLE_BASE_MINOR,
  t.TAX_MINOR,
  t.VENDOR_CHARGED_MINOR,
  (t.TAXABLE_BASE_MINOR / c.MINOR_PER_MAJOR)::NUMBER(38,2)              AS TAXABLE_BASE_AMOUNT,
  (t.TAX_MINOR / c.MINOR_PER_MAJOR)::NUMBER(38,2)                       AS TAX_AMOUNT,
  (COALESCE(t.VENDOR_CHARGED_MINOR,0) / c.MINOR_PER_MAJOR)::NUMBER(38,2) AS VENDOR_CHARGED_AMOUNT,
  -- tax the vendor SHOULD have charged = base x rate (0 when base is 0)
  (ROUND(t.TAXABLE_BASE_MINOR * t.RATE) / c.MINOR_PER_MAJOR)::NUMBER(38,2) AS EXPECTED_TAX_AMOUNT,
  CASE WHEN t.TREATMENT = 'use_tax_accrual'
       THEN (t.TAX_MINOR / c.MINOR_PER_MAJOR)::NUMBER(38,2) ELSE 0 END  AS USE_TAX_TO_ACCRUE_AMOUNT,
  CASE WHEN t.TREATMENT = 'overcharged'
       THEN ((COALESCE(t.VENDOR_CHARGED_MINOR, t.TAX_MINOR) - ROUND(t.TAXABLE_BASE_MINOR * t.RATE))
             / c.MINOR_PER_MAJOR)::NUMBER(38,2) ELSE 0 END                AS OVERCHARGE_AMOUNT,
  CASE WHEN t.ACCRUAL AND t.REGIME <> 'US_SUT'
       THEN (t.TAX_MINOR / c.MINOR_PER_MAJOR)::NUMBER(38,2) ELSE 0 END  AS SELF_ASSESSED_VAT_AMOUNT
FROM HALIDE_TAX.RAW.TAX_LINES t
JOIN HALIDE_TAX.RAW.DOCUMENTS d  ON d.NUMBER = t.DOCUMENT_NUMBER
JOIN HALIDE_TAX.CORE.CURRENCIES c ON c.CURRENCY = d.CURRENCY;

-- ---------- GL lines (posted journal lines, major units) ------------------------------
CREATE OR REPLACE VIEW HALIDE_TAX.CORE.GL_LINES
  COMMENT = 'Posted general-ledger journal lines in major units. AMOUNT is signed: debit positive, credit negative. Account 2410 = US use tax payable; 2420 = self-assessed VAT/GST payable.'
AS
SELECT
  l.ENTRY_NUMBER,
  l.LINE_NO,
  e.ENTRY_TYPE,
  e.HEADER_TEXT,
  e.STATUS                                         AS ENTRY_STATUS,
  e.POSTED_BY,
  l.ENTITY_ID,
  l.POSTING_DATE,
  TO_CHAR(l.POSTING_DATE, 'YYYY-MM')               AS CLOSE_PERIOD,
  l.ACCOUNT_CODE,
  l.ACCOUNT_NAME,
  a.TYPE                                           AS ACCOUNT_TYPE,
  a.CATEGORY                                       AS ACCOUNT_CATEGORY,
  a.CONTROL_TYPE                                   AS ACCOUNT_CONTROL_TYPE,
  l.CURRENCY,
  (l.AMOUNT_MINOR / c.MINOR_PER_MAJOR)::NUMBER(38,2)                          AS AMOUNT,
  (GREATEST(l.AMOUNT_MINOR,0) / c.MINOR_PER_MAJOR)::NUMBER(38,2)              AS DEBIT_AMOUNT,
  (GREATEST(-l.AMOUNT_MINOR,0) / c.MINOR_PER_MAJOR)::NUMBER(38,2)             AS CREDIT_AMOUNT,
  l.ENTITY_CURRENCY,
  (l.ENTITY_AMOUNT_MINOR / ce.MINOR_PER_MAJOR)::NUMBER(38,2)                  AS ENTITY_AMOUNT,
  l.GROUP_CURRENCY,
  (l.GROUP_AMOUNT_MINOR / cg.MINOR_PER_MAJOR)::NUMBER(38,2)                   AS GROUP_AMOUNT_USD,
  l.TAX_JURISDICTION,
  l.CUSTOMER                                       AS CUSTOMER_ID,
  l.SUPPLIER                                       AS SUPPLIER_ID,
  l.COST_CENTER,
  l.DEPARTMENT,
  l.SOURCE_DOCUMENT,
  l.LINE_TYPE,
  l.RULE_ID,
  l.DESCRIPTION,
  l.AMOUNT_MINOR
FROM HALIDE_TAX.RAW.JOURNAL_LINES l
JOIN HALIDE_TAX.RAW.JOURNAL_ENTRIES e ON e.NUMBER = l.ENTRY_NUMBER
LEFT JOIN HALIDE_TAX.RAW.ACCOUNTS a   ON a.CODE = l.ACCOUNT_CODE
JOIN HALIDE_TAX.CORE.CURRENCIES c     ON c.CURRENCY = l.CURRENCY
JOIN HALIDE_TAX.CORE.CURRENCIES ce    ON ce.CURRENCY = l.ENTITY_CURRENCY
JOIN HALIDE_TAX.CORE.CURRENCIES cg    ON cg.CURRENCY = l.GROUP_CURRENCY;

-- ---------- supplier invoices + close-desk status (THE worklist) ----------------------
CREATE OR REPLACE VIEW HALIDE_TAX.CORE.SUPPLIER_INVOICES
  COMMENT = 'One row per supplier (vendor) invoice with its tax outcome and the close action needed. CLOSE_ACTION: ACCRUE_USE_TAX (use tax owed, not yet in GL), USE_TAX_ACCRUED (already in GL), VENDOR_OVERCHARGE (vendor charged tax not due -> refund/credit memo), SELF_ASSESS_VAT / SELF_ASSESSED_VAT_IN_GL (EU reverse charge or acquisition VAT), VENDOR_TAX_OK, NO_TAX_DUE.'
AS
WITH tl AS (
  SELECT DOCUMENT_NUMBER,
         SUM(USE_TAX_TO_ACCRUE_AMOUNT)  AS USE_TAX_TO_ACCRUE_AMOUNT,
         SUM(OVERCHARGE_AMOUNT)         AS OVERCHARGE_AMOUNT,
         SUM(SELF_ASSESSED_VAT_AMOUNT)  AS SELF_ASSESSED_VAT_AMOUNT,
         SUM(VENDOR_CHARGED_AMOUNT)     AS VENDOR_CHARGED_TAX_AMOUNT,
         MAX(CASE WHEN TREATMENT IN ('use_tax_accrual','overcharged','vendor_charged','reverse_charge','acquisition_vat')
                  THEN JURISDICTION_NAME END) AS TAX_JURISDICTION_NAME,
         MAX(CASE WHEN TREATMENT IN ('use_tax_accrual','overcharged','vendor_charged','reverse_charge','acquisition_vat')
                  THEN RATE END)        AS TAX_RATE,
         LISTAGG(DISTINCT RULE_ID, ', ') AS RULE_IDS
  FROM HALIDE_TAX.CORE.TAX_LINES
  GROUP BY DOCUMENT_NUMBER
),
gl AS (
  SELECT SOURCE_DOCUMENT,
         MAX(ENTRY_NUMBER) AS GL_ENTRY_NUMBER,
         -SUM(CASE WHEN ACCOUNT_CODE = '2410' THEN AMOUNT ELSE 0 END) AS USE_TAX_IN_GL_AMOUNT,
         -SUM(CASE WHEN ACCOUNT_CODE = '2420' THEN AMOUNT ELSE 0 END) AS SELF_ASSESSED_VAT_IN_GL_AMOUNT
  FROM HALIDE_TAX.CORE.GL_LINES
  GROUP BY SOURCE_DOCUMENT
)
SELECT
  d.NUMBER                                        AS DOCUMENT_NUMBER,
  d.ENTITY_ID,
  d.ENTITY_NAME,
  s.SUPPLIER_ID,
  d.PARTY                                         AS SUPPLIER_NAME,
  s.SUPPLIER_COUNTRY,
  s.SUPPLIER_INDUSTRY,
  d.CURRENCY,
  d.DOCUMENT_DATE,
  TO_CHAR(d.DOCUMENT_DATE, 'YYYY-MM')             AS CLOSE_PERIOD,
  d.STATUS                                        AS INVOICE_STATUS,
  d.TREATMENTS                                    AS TAX_TREATMENT,
  (d.TAXABLE_MINOR / c.MINOR_PER_MAJOR)::NUMBER(38,2) AS TAXABLE_AMOUNT,
  (d.TAX_MINOR     / c.MINOR_PER_MAJOR)::NUMBER(38,2) AS VENDOR_TAX_CHARGED_AMOUNT,
  (d.ACCRUED_MINOR / c.MINOR_PER_MAJOR)::NUMBER(38,2) AS SELF_ASSESSED_TAX_AMOUNT,
  COALESCE(tl.USE_TAX_TO_ACCRUE_AMOUNT, 0)        AS USE_TAX_OWED_AMOUNT,        -- total per tax engine
  GREATEST(COALESCE(tl.USE_TAX_TO_ACCRUE_AMOUNT, 0) - COALESCE(gl.USE_TAX_IN_GL_AMOUNT, 0), 0)
                                                  AS USE_TAX_TO_ACCRUE_AMOUNT,   -- owed and NOT yet in GL
  COALESCE(tl.OVERCHARGE_AMOUNT, 0)               AS OVERCHARGE_AMOUNT,
  COALESCE(tl.SELF_ASSESSED_VAT_AMOUNT, 0)        AS SELF_ASSESSED_VAT_AMOUNT,
  tl.TAX_JURISDICTION_NAME,
  tl.TAX_RATE,
  tl.RULE_IDS,
  gl.GL_ENTRY_NUMBER,
  COALESCE(gl.USE_TAX_IN_GL_AMOUNT, 0)            AS USE_TAX_IN_GL_AMOUNT,
  COALESCE(gl.SELF_ASSESSED_VAT_IN_GL_AMOUNT, 0)  AS SELF_ASSESSED_VAT_IN_GL_AMOUNT,
  CASE
    WHEN COALESCE(tl.USE_TAX_TO_ACCRUE_AMOUNT,0) > 0 AND COALESCE(gl.USE_TAX_IN_GL_AMOUNT,0) = 0 THEN 'ACCRUE_USE_TAX'
    WHEN COALESCE(tl.USE_TAX_TO_ACCRUE_AMOUNT,0) > 0                                         THEN 'USE_TAX_ACCRUED'
    WHEN COALESCE(tl.OVERCHARGE_AMOUNT,0) > 0                                                THEN 'VENDOR_OVERCHARGE'
    WHEN d.TREATMENTS IN ('reverse_charge','acquisition_vat')
         AND COALESCE(gl.SELF_ASSESSED_VAT_IN_GL_AMOUNT,0) > 0                               THEN 'SELF_ASSESSED_VAT_IN_GL'
    WHEN d.TREATMENTS IN ('reverse_charge','acquisition_vat')                                THEN 'SELF_ASSESS_VAT'
    WHEN d.TREATMENTS = 'vendor_charged'                                                     THEN 'VENDOR_TAX_OK'
    ELSE 'NO_TAX_DUE'
  END                                             AS CLOSE_ACTION
FROM HALIDE_TAX.RAW.DOCUMENTS d
JOIN HALIDE_TAX.CORE.CURRENCIES c ON c.CURRENCY = d.CURRENCY
LEFT JOIN HALIDE_TAX.CORE.SUPPLIERS s ON s.SUPPLIER_NAME = d.PARTY
LEFT JOIN tl ON tl.DOCUMENT_NUMBER = d.NUMBER
LEFT JOIN gl ON gl.SOURCE_DOCUMENT = d.NUMBER
WHERE d.DOC_TYPE = 'supplier_invoice';

-- ---------- rate content (demo rates from rates.yml) ---------------------------------
CREATE OR REPLACE VIEW HALIDE_TAX.CORE.RATE_COMPONENTS
  COMMENT = 'Demo tax-rate content by jurisdiction and component (state/county/city/district or national/local). Demo data: verify current rates with the authority.'
AS SELECT * FROM HALIDE_TAX.RAW.RATE_COMPONENTS;

-- ---------- expected results (sanity checks) -----------------------------------------
-- 28 supplier invoices; worklist by action:
SELECT CLOSE_ACTION, COUNT(*) AS N, LISTAGG(DOCUMENT_NUMBER, ', ') AS DOCS
FROM HALIDE_TAX.CORE.SUPPLIER_INVOICES GROUP BY 1 ORDER BY 1;
--   ACCRUE_USE_TAX           1  SINV-US-2026-000012 (Stackworks, USD 3,465.00, Sep 2026)
--   USE_TAX_ACCRUED          2  SINV-US-2026-000002, SINV-US-2026-000008 (USD 3,168.00 each)
--   VENDOR_OVERCHARGE        1  SINV-US-2026-000013 (Hyperscale Compute, USD 103,500.00)
--   SELF_ASSESSED_VAT_IN_GL  3  SINV-IE-2026-000001/-000004 (EUR 4,140.00 each), SINV-IE-2026-000003 (EUR 552,000.00)
--   VENDOR_TAX_OK           10  JP x6, SG x2, IE x2
--   NO_TAX_DUE              11
-- JPY check: SINV-JP-2026-000005 VENDOR_TAX_CHARGED_AMOUNT should be 22000.00 (JPY 22,000)
SELECT DOCUMENT_NUMBER, CURRENCY, TAXABLE_AMOUNT, VENDOR_TAX_CHARGED_AMOUNT
FROM HALIDE_TAX.CORE.SUPPLIER_INVOICES WHERE DOCUMENT_NUMBER = 'SINV-JP-2026-000005';
-- GL balances: should be 0 per entry (balanced) — expect zero rows
SELECT ENTRY_NUMBER, SUM(AMOUNT_MINOR) FROM HALIDE_TAX.CORE.GL_LINES GROUP BY 1 HAVING SUM(AMOUNT_MINOR) <> 0;
