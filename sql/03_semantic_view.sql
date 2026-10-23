-- =====================================================================================
-- 03_semantic_view.sql — semantic view for Cortex Analyst: HALIDE_TAX.CORE.TAX_CLOSE_SV
-- Run AFTER 01_core_views.sql and 04_tools.sql (it references AGENT.PROPOSED_JOURNALS).
--   >>> If you have not run 04 yet, run 04 first (04 only needs 01). <<<
-- Role: HALIDE_BUILDER.
-- Docs verified 2026-10-23:
--   https://docs.snowflake.com/en/sql-reference/sql/create-semantic-view
--   https://docs.snowflake.com/en/user-guide/views-semantic/sql
-- Grammar rules that bite: clause order TABLES > RELATIONSHIPS > FACTS > DIMENSIONS >
--   METRICS > COMMENT > AI_SQL_GENERATION > AI_QUESTION_CATEGORIZATION > AI_VERIFIED_QUERIES
--   > COPY GRANTS. Every expression is prefixed with its table alias. A referenced table must
--   have a PRIMARY KEY. "x AS X" (same name) resolves to the physical column.
--
-- FASTER ALTERNATIVE (if this DDL fights you): Snowsight » AI & ML » Cortex Analyst »
--   Create new » Semantic View Autopilot, pick CORE.SUPPLIER_INVOICES, CORE.TAX_LINES,
--   CORE.ENTITIES, CORE.SUPPLIERS, CORE.GL_LINES, AGENT.PROPOSED_JOURNALS; name it
--   TAX_CLOSE_SV in HALIDE_TAX.CORE; then add the synonyms below in the editor.
--   https://docs.snowflake.com/en/user-guide/views-semantic/autopilot
-- =====================================================================================
USE ROLE HALIDE_BUILDER;
USE WAREHOUSE HALIDE_WH;
USE SCHEMA HALIDE_TAX.CORE;

CREATE OR REPLACE SEMANTIC VIEW HALIDE_TAX.CORE.TAX_CLOSE_SV
  TABLES (
    si  AS HALIDE_TAX.CORE.SUPPLIER_INVOICES PRIMARY KEY (DOCUMENT_NUMBER)
        WITH SYNONYMS = ('supplier invoices', 'vendor invoices', 'purchase invoices', 'AP invoices', 'bills', 'close worklist')
        COMMENT = 'One row per supplier invoice with its tax outcome and the close action needed',
    tl  AS HALIDE_TAX.CORE.TAX_LINES PRIMARY KEY (DOCUMENT_NUMBER, LINE_REF)
        WITH SYNONYMS = ('tax lines', 'tax determinations', 'tax calculations')
        COMMENT = 'Tax engine determination lines for supplier AND customer invoices',
    ent AS HALIDE_TAX.CORE.ENTITIES PRIMARY KEY (ENTITY_ID)
        WITH SYNONYMS = ('legal entities', 'companies', 'subsidiaries')
        COMMENT = 'Halide Labs legal entities: US = Halide Labs (parent, USD), IE = Halide Labs Ireland (EUR), JP = Halide Labs Japan (JPY), SG = Halide Labs Asia (Singapore, SGD)',
    sup AS HALIDE_TAX.CORE.SUPPLIERS PRIMARY KEY (SUPPLIER_ID)
        WITH SYNONYMS = ('vendors', 'suppliers')
        COMMENT = 'Vendors of Halide Labs',
    gl  AS HALIDE_TAX.CORE.GL_LINES PRIMARY KEY (ENTRY_NUMBER, LINE_NO)
        WITH SYNONYMS = ('general ledger', 'journal lines', 'posted journals', 'ledger')
        COMMENT = 'Posted GL journal lines; amount is signed (debit +, credit -)',
    pj  AS HALIDE_TAX.AGENT.PROPOSED_JOURNALS PRIMARY KEY (PROPOSAL_ID)
        WITH SYNONYMS = ('proposed journals', 'proposals', 'pending accruals', 'journal proposals')
        COMMENT = 'Tax journal proposals created by the agent or analysts; pending until a Controller approves; never posted from here',
    rc  AS HALIDE_TAX.CORE.RATE_COMPONENTS
        WITH SYNONYMS = ('tax rates', 'rate table', 'rate components')
        COMMENT = 'Demo effective-dated tax rate content by jurisdiction and component'
  )
  RELATIONSHIPS (
    invoice_to_entity   AS si (ENTITY_ID)       REFERENCES ent,
    invoice_to_supplier AS si (SUPPLIER_ID)     REFERENCES sup,
    taxline_to_entity   AS tl (ENTITY_ID)       REFERENCES ent,
    gl_to_entity        AS gl (ENTITY_ID)       REFERENCES ent,
    proposal_to_invoice AS pj (SOURCE_DOCUMENT) REFERENCES si
  )
  FACTS (
    si.taxable_amount            AS TAXABLE_AMOUNT
      COMMENT = 'Taxable base of the invoice, invoice currency, major units',
    si.vendor_tax_charged_amount AS VENDOR_TAX_CHARGED_AMOUNT
      WITH SYNONYMS = ('tax charged by vendor', 'sales tax paid', 'VAT charged', 'JCT charged', 'GST charged')
      COMMENT = 'Tax the vendor put on the invoice',
    si.use_tax_owed_amount       AS USE_TAX_OWED_AMOUNT
      WITH SYNONYMS = ('use tax', 'use tax owed', 'total use tax', 'consumer use tax', 'self-assessed use tax')
      COMMENT = 'TOTAL US use tax owed on the invoice per the tax engine (vendor charged no sales tax on a taxable purchase). Equals USE_TAX_IN_GL_AMOUNT + USE_TAX_TO_ACCRUE_AMOUNT. Never add it to either of those.',
    si.use_tax_to_accrue_amount  AS USE_TAX_TO_ACCRUE_AMOUNT
      WITH SYNONYMS = ('use tax still to accrue', 'outstanding use tax', 'unaccrued use tax', 'use tax accrual needed')
      COMMENT = 'Part of USE_TAX_OWED_AMOUNT NOT yet posted to the GL (0 once accrued). Owed = in GL + to accrue.',
    si.overcharge_amount         AS OVERCHARGE_AMOUNT
      WITH SYNONYMS = ('overcharge', 'overcharged tax', 'over-collected tax', 'refund due from vendor', 'tax charged in error')
      COMMENT = 'Tax the vendor charged that was not due (vendor-charged minus expected)',
    si.self_assessed_vat_amount  AS SELF_ASSESSED_VAT_AMOUNT
      WITH SYNONYMS = ('reverse charge VAT', 'self-assessed VAT', 'acquisition VAT')
      COMMENT = 'VAT Halide Labs Ireland self-assesses under reverse charge or acquisition VAT',
    si.use_tax_in_gl_amount      AS USE_TAX_IN_GL_AMOUNT
      COMMENT = 'Part of USE_TAX_OWED_AMOUNT already posted to account 2410 for this invoice',
    tl.tax_amount                AS TAX_AMOUNT
      COMMENT = 'Tax amount on the line, document currency',
    tl.taxable_base_amount       AS TAXABLE_BASE_AMOUNT,
    tl.expected_tax_amount       AS EXPECTED_TAX_AMOUNT
      COMMENT = 'Taxable base x rate',
    tl.vendor_charged_amount     AS VENDOR_CHARGED_AMOUNT,
    tl.tax_rate                  AS RATE
      COMMENT = 'Combined rate as a decimal (0.0825 = 8.25%)',
    gl.amount                    AS AMOUNT
      COMMENT = 'Signed amount in transaction currency, debit positive',
    gl.debit_amount              AS DEBIT_AMOUNT,
    gl.credit_amount             AS CREDIT_AMOUNT,
    pj.total_amount              AS TOTAL_AMOUNT
      COMMENT = 'Proposal amount (total debits = total credits)',
    rc.component_rate            AS RATE
      COMMENT = 'Component rate as a decimal'
  )
  DIMENSIONS (
    si.document_number   AS DOCUMENT_NUMBER WITH SYNONYMS = ('invoice number', 'invoice', 'document')
      COMMENT = 'Supplier invoice number, e.g. SINV-US-2026-000012',
    si.supplier_name     AS SUPPLIER_NAME WITH SYNONYMS = ('vendor', 'vendor name', 'supplier'),
    si.supplier_country  AS SUPPLIER_COUNTRY,
    si.invoice_currency  AS CURRENCY WITH SYNONYMS = ('currency')
      COMMENT = 'Invoice currency; amounts are in this currency',
    si.document_date     AS DOCUMENT_DATE WITH SYNONYMS = ('invoice date'),
    si.close_period      AS CLOSE_PERIOD WITH SYNONYMS = ('period', 'month', 'close month')
      COMMENT = 'YYYY-MM of the invoice date, e.g. 2026-09 = September 2026',
    si.invoice_status    AS INVOICE_STATUS WITH SYNONYMS = ('AP status', 'payment status')
      COMMENT = 'posted, settled, pending_approval or on_hold',
    si.tax_treatment     AS TAX_TREATMENT WITH SYNONYMS = ('treatment', 'tax outcome')
      COMMENT = 'use_tax_accrual, overcharged, vendor_charged, reverse_charge, acquisition_vat, not_taxable, out_of_scope',
    si.close_action      AS CLOSE_ACTION WITH SYNONYMS = ('action needed', 'next step', 'close status', 'to do')
      COMMENT = 'ACCRUE_USE_TAX = use tax owed and not yet in GL; USE_TAX_ACCRUED = already in GL; VENDOR_OVERCHARGE = refund/credit memo needed; SELF_ASSESSED_VAT_IN_GL; VENDOR_TAX_OK; NO_TAX_DUE',
    si.tax_jurisdiction  AS TAX_JURISDICTION_NAME WITH SYNONYMS = ('jurisdiction', 'state', 'city'),
    si.rule_ids          AS RULE_IDS WITH SYNONYMS = ('tax rule', 'rule id'),
    si.gl_entry_number   AS GL_ENTRY_NUMBER WITH SYNONYMS = ('journal entry', 'posted entry'),
    tl.line_document     AS DOCUMENT_NUMBER,
    tl.doc_type          AS DOC_TYPE COMMENT = 'supplier_invoice or customer_invoice',
    tl.counterparty      AS COUNTERPARTY_NAME WITH SYNONYMS = ('customer or vendor'),
    tl.line_currency     AS CURRENCY,
    tl.line_period       AS CLOSE_PERIOD,
    tl.regime            AS REGIME COMMENT = 'US_SUT, EU_VAT, UK_VAT, JP_JCT, SG_GST, AU_GST, IN_GST, CH_VAT',
    tl.jurisdiction_code AS JURISDICTION_CODE,
    tl.jurisdiction_name AS JURISDICTION_NAME,
    tl.treatment         AS TREATMENT,
    tl.rule_id           AS RULE_ID,
    tl.tax_type          AS TAX_TYPE,
    ent.entity_id        AS ENTITY_ID WITH SYNONYMS = ('entity code')
      COMMENT = 'US, IE, JP or SG',
    ent.entity_name      AS ENTITY_NAME WITH SYNONYMS = ('entity', 'company', 'legal entity', 'subsidiary'),
    ent.entity_country   AS ENTITY_COUNTRY,
    ent.entity_currency  AS ENTITY_CURRENCY WITH SYNONYMS = ('functional currency'),
    sup.supplier_industry AS SUPPLIER_INDUSTRY WITH SYNONYMS = ('vendor category', 'what the vendor sells'),
    gl.entry_number      AS ENTRY_NUMBER,
    gl.account_code      AS ACCOUNT_CODE WITH SYNONYMS = ('GL account', 'account number')
      COMMENT = '2410 = US use tax payable; 2420 = self-assessed VAT/GST payable; 1400 = input VAT recoverable',
    gl.account_name      AS ACCOUNT_NAME,
    gl.account_type      AS ACCOUNT_TYPE,
    gl.posting_date      AS POSTING_DATE,
    gl.gl_period         AS CLOSE_PERIOD,
    gl.gl_currency       AS CURRENCY,
    gl.source_document   AS SOURCE_DOCUMENT,
    gl.line_type         AS LINE_TYPE,
    pj.proposal_id       AS PROPOSAL_ID,
    pj.proposal_type     AS PROPOSAL_TYPE,
    pj.proposal_status   AS STATUS WITH SYNONYMS = ('approval status')
      COMMENT = 'pending, approved or rejected',
    pj.proposal_document AS SOURCE_DOCUMENT,
    pj.proposal_currency AS CURRENCY,
    pj.proposed_by       AS PROPOSED_BY_USER WITH SYNONYMS = ('preparer', 'maker'),
    pj.decided_by        AS DECIDED_BY_USER WITH SYNONYMS = ('approver', 'checker'),
    rc.rate_jurisdiction_code AS JURISDICTION_CODE,
    rc.rate_jurisdiction_name AS JURISDICTION_NAME,
    rc.rate_level        AS COMPONENT_LEVEL COMMENT = 'state, county, city, district, national, local, country',
    rc.component_name    AS COMPONENT_NAME,
    rc.effective_from    AS EFFECTIVE_FROM,
    rc.effective_to      AS EFFECTIVE_TO
  )
  METRICS (
    si.invoice_count             AS COUNT(si.DOCUMENT_NUMBER)
      WITH SYNONYMS = ('number of invoices'),
    si.total_taxable_amount      AS SUM(si.taxable_amount),
    si.total_vendor_tax_charged  AS SUM(si.vendor_tax_charged_amount),
    si.total_use_tax_owed        AS SUM(si.use_tax_owed_amount)
      WITH SYNONYMS = ('total use tax', 'use tax liability'),
    si.total_use_tax_to_accrue   AS SUM(si.use_tax_to_accrue_amount)
      WITH SYNONYMS = ('use tax not yet accrued', 'outstanding use tax'),
    si.total_overcharge          AS SUM(si.overcharge_amount)
      WITH SYNONYMS = ('total overcharge', 'total refund due'),
    si.total_self_assessed_vat   AS SUM(si.self_assessed_vat_amount),
    si.total_use_tax_in_gl       AS SUM(si.use_tax_in_gl_amount),
    tl.total_tax_amount          AS SUM(tl.tax_amount),
    tl.total_taxable_base        AS SUM(tl.taxable_base_amount),
    tl.tax_line_count            AS COUNT(tl.LINE_REF),
    gl.net_amount                AS SUM(gl.amount) WITH SYNONYMS = ('balance', 'net balance'),
    gl.total_debits              AS SUM(gl.debit_amount),
    gl.total_credits             AS SUM(gl.credit_amount),
    pj.proposal_count            AS COUNT(pj.PROPOSAL_ID),
    pj.total_proposed_amount     AS SUM(pj.total_amount),
    rc.combined_rate             AS SUM(rc.component_rate)
      COMMENT = 'Sum of component rates in force; filter on a single date to get the combined rate'
  )
  COMMENT = 'Halide Labs (fictional) indirect tax close desk: supplier invoice tax review, use tax accruals, vendor overcharges, EU reverse charge, GL tax accounts and journal proposals'
  AI_SQL_GENERATION 'All amounts are in MAJOR units of the row currency (USD, EUR, SGD have 2 decimals; JPY has 0). NEVER add amounts of different currencies together: always GROUP BY or filter on the currency column and return the currency code next to every amount. A close period is the YYYY-MM of the invoice date, so "September 2026" means CLOSE_PERIOD = ''2026-09'' and Q3 2026 means 2026-07 to 2026-09. "Needs use tax accrued" / "use tax to accrue" means CLOSE_ACTION = ''ACCRUE_USE_TAX''. Use tax amounts: total use tax = SUM(USE_TAX_OWED_AMOUNT); already in the GL = SUM(USE_TAX_IN_GL_AMOUNT); still to accrue = SUM(USE_TAX_TO_ACCRUE_AMOUNT); owed = in GL + to accrue, so NEVER add USE_TAX_OWED_AMOUNT to either of the other two. "Overcharge" means CLOSE_ACTION = ''VENDOR_OVERCHARGE'' or OVERCHARGE_AMOUNT > 0. For combined tax rates use the rate on the tax lines; rates are decimals (0.0825 = 8.25%). Always include DOCUMENT_NUMBER and SUPPLIER_NAME when listing invoices.'
  AI_QUESTION_CATEGORIZATION 'This view covers only Halide Labs data (a fictional company). If asked about tax law or rates for jurisdictions not in the data, say the data does not cover it.'
  -- >>> VQ START  (if CREATE fails pointing at AI_VERIFIED_QUERIES, delete from here to VQ END and re-run)
  AI_VERIFIED_QUERIES (
    use_tax_to_accrue_sep AS (
      QUESTION 'Which supplier invoices need use tax accrued in September 2026, and how much?'
      VERIFIED_AT 1792713600
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = tax_technology)'
      SQL 'SELECT si.document_number, si.supplier_name, si.invoice_currency, si.tax_jurisdiction, si.use_tax_to_accrue_amount FROM si WHERE si.close_action = ''ACCRUE_USE_TAX'' AND si.close_period = ''2026-09'' ORDER BY si.document_number'
    ),
    vendor_overcharges AS (
      QUESTION 'Where did a vendor overcharge us on tax?'
      VERIFIED_AT 1792713600
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = tax_technology)'
      SQL 'SELECT si.document_number, si.supplier_name, si.invoice_status, si.invoice_currency, si.tax_jurisdiction, si.overcharge_amount FROM si WHERE si.overcharge_amount > 0 ORDER BY si.overcharge_amount DESC'
    ),
    close_worklist AS (
      QUESTION 'Show the supplier invoice tax close worklist by close action'
      VERIFIED_AT 1792713600
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = tax_technology)'
      SQL 'SELECT si.close_action, si.invoice_currency, COUNT(si.document_number) AS invoice_count, SUM(si.use_tax_to_accrue_amount) AS use_tax_to_accrue, SUM(si.overcharge_amount) AS overcharge FROM si GROUP BY si.close_action, si.invoice_currency ORDER BY si.close_action, si.invoice_currency'
    )
  )
  -- <<< VQ END
  COPY GRANTS;

-- ---------- checks -------------------------------------------------------------------
DESCRIBE SEMANTIC VIEW HALIDE_TAX.CORE.TAX_CLOSE_SV;

SELECT * FROM SEMANTIC_VIEW(
  HALIDE_TAX.CORE.TAX_CLOSE_SV
  DIMENSIONS si.close_action, si.invoice_currency
  METRICS si.invoice_count, si.total_use_tax_to_accrue, si.total_overcharge
) ORDER BY 1, 2;
-- expect ACCRUE_USE_TAX/USD 1 3465.00 ; VENDOR_OVERCHARGE/USD 1 0 103500.00 ; USE_TAX_ACCRUED/USD 2 6336.00 ...

SELECT * FROM SEMANTIC_VIEW(
  HALIDE_TAX.CORE.TAX_CLOSE_SV
  DIMENSIONS ent.entity_name, si.invoice_currency
  METRICS si.total_vendor_tax_charged
) ORDER BY 1;

-- ---------- grants (SELECT on the semantic view is what Analyst needs; base views granted in 04) ----
GRANT SELECT ON SEMANTIC VIEW HALIDE_TAX.CORE.TAX_CLOSE_SV TO ROLE TAX_AGENT;
-- Some doc pages also ask for SELECT on the underlying tables/views for agents: already granted
-- on CORE views in 04_tools.sql; PROPOSED_JOURNALS SELECT also granted there.
