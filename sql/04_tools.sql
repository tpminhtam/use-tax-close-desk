-- =====================================================================================
-- 04_tools.sql  —  governed write-back: the agent PROPOSES, a human CONTROLLER APPROVES,
--                   the ERP POSTS. Nothing here posts to the general ledger.
-- Run AFTER 01_core_views.sql.  Role: HALIDE_BUILDER (owns every object below).
--
-- WHY EXECUTE AS OWNER (the segregation-of-duties design):
--   * TAX_AGENT / TAX_ANALYST / CONTROLLER get NO INSERT/UPDATE/DELETE on any AGENT table.
--     The only way to write is to CALL a procedure. Owner's-rights procedures run with
--     HALIDE_BUILDER's privileges, so they can write, but ONLY the fixed SQL inside them:
--       - amounts are read from RAW.TAX_LINES (deterministic, not typed by the model),
--       - status is hard-coded to 'pending', entries are balanced by construction,
--       - every call writes AGENT.AUDIT_LOG.
--   * If these were EXECUTE AS CALLER, every caller (incl. the agent) would need INSERT/UPDATE
--     on PROPOSED_JOURNALS, so it could write status='approved' with any amount -> SoD broken.
--   * WHO may approve is enforced by GRANTS: USAGE on APPROVE_PROPOSAL / REJECT_PROPOSAL is
--     granted ONLY to CONTROLLER. The agent is never given an approve tool, and even if it were,
--     a TAX_AGENT/TAX_ANALYST caller would get "insufficient privileges".
--   * Maker-checker inside APPROVE_PROPOSAL: approver user must differ from the preparer.
--   * There is NO post procedure. Approved proposals appear in AGENT.APPROVED_FOR_POSTING for
--     the ERP (myERP) to post; the tax desk cannot post.
-- VERIFY: inside an owner's-rights procedure CURRENT_ROLE() returns the OWNER role; we record
--   CURRENT_USER() as the actor (session user) — confirm in the audit log after first call.
--   https://docs.snowflake.com/en/developer-guide/stored-procedure/stored-procedures-rights
-- =====================================================================================
USE ROLE HALIDE_BUILDER;
USE WAREHOUSE HALIDE_WH;
USE SCHEMA HALIDE_TAX.AGENT;

-- ---------- tables -------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS HALIDE_TAX.AGENT.PROPOSAL_SEQ START = 1 INCREMENT = 1;
CREATE SEQUENCE IF NOT EXISTS HALIDE_TAX.AGENT.FLAG_SEQ START = 1 INCREMENT = 1;

CREATE TABLE IF NOT EXISTS HALIDE_TAX.AGENT.PROPOSED_JOURNALS (
  PROPOSAL_ID        VARCHAR(20)  NOT NULL PRIMARY KEY,
  PROPOSAL_TYPE      VARCHAR(30)  NOT NULL,          -- USE_TAX_ACCRUAL
  SOURCE_DOCUMENT    VARCHAR(30)  NOT NULL,
  ENTITY_ID          VARCHAR(5),
  SUPPLIER_NAME      VARCHAR(100),
  CURRENCY           VARCHAR(3),
  CLOSE_PERIOD       VARCHAR(7),
  TOTAL_MINOR        NUMBER(38,0),                   -- total debits = total credits
  TOTAL_AMOUNT       NUMBER(38,2),
  AMOUNT_DISPLAY     VARCHAR(50),
  STATUS             VARCHAR(20)  NOT NULL,          -- pending | approved | rejected
  POLICY_ID          VARCHAR(20),
  RULE_IDS           VARCHAR(200),
  RATIONALE          VARCHAR(2000),
  PROPOSED_BY_USER   VARCHAR(200),
  PROPOSED_BY_ROLE   VARCHAR(200),
  PROPOSED_AT        TIMESTAMP_LTZ,
  DECIDED_BY_USER    VARCHAR(200),
  DECIDED_AT         TIMESTAMP_LTZ,
  DECISION_COMMENT   VARCHAR(2000),
  EXPORTED_TO_ERP    BOOLEAN DEFAULT FALSE
) COMMENT = 'Tax journal PROPOSALS. Never posted from here; approved rows are exported to the ERP.';

CREATE TABLE IF NOT EXISTS HALIDE_TAX.AGENT.PROPOSED_JOURNAL_LINES (
  PROPOSAL_ID        VARCHAR(20) NOT NULL,
  LINE_NO            NUMBER(3,0) NOT NULL,
  ACCOUNT_CODE       VARCHAR(10),
  ACCOUNT_NAME       VARCHAR(100),
  DEBIT_MINOR        NUMBER(38,0),
  CREDIT_MINOR       NUMBER(38,0),
  DEBIT_AMOUNT       NUMBER(38,2),
  CREDIT_AMOUNT      NUMBER(38,2),
  CURRENCY           VARCHAR(3),
  TAX_JURISDICTION   VARCHAR(20),
  DESCRIPTION        VARCHAR(500)
);

CREATE TABLE IF NOT EXISTS HALIDE_TAX.AGENT.VENDOR_TAX_FLAGS (
  FLAG_ID            VARCHAR(20) NOT NULL PRIMARY KEY,
  SOURCE_DOCUMENT    VARCHAR(30) NOT NULL,
  ENTITY_ID          VARCHAR(5),
  SUPPLIER_NAME      VARCHAR(100),
  CURRENCY           VARCHAR(3),
  OVERCHARGE_MINOR   NUMBER(38,0),
  OVERCHARGE_AMOUNT  NUMBER(38,2),
  AMOUNT_DISPLAY     VARCHAR(50),
  TAX_JURISDICTION   VARCHAR(100),
  RECOMMENDED_ACTION VARCHAR(1000),
  NOTE               VARCHAR(2000),
  STATUS             VARCHAR(20),                    -- open | closed
  POLICY_ID          VARCHAR(20),
  FLAGGED_BY_USER    VARCHAR(200),
  FLAGGED_BY_ROLE    VARCHAR(200),
  FLAGGED_AT         TIMESTAMP_LTZ
) COMMENT = 'Vendor sales-tax overcharges flagged for credit memo / refund (HL-TAX-POL-002).';

CREATE TABLE IF NOT EXISTS HALIDE_TAX.AGENT.AUDIT_LOG (
  EVENT_ID           NUMBER AUTOINCREMENT START 1 INCREMENT 1,
  EVENT_TS           TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
  ACTOR_USER         VARCHAR(200),
  ACTOR_ROLE         VARCHAR(200),
  ACTION             VARCHAR(50),
  SOURCE_DOCUMENT    VARCHAR(30),
  OBJECT_ID          VARCHAR(30),
  OUTCOME            VARCHAR(50),
  DETAILS            VARIANT
) COMMENT = 'Append-only audit trail of every propose / flag / approve / reject call (HL-TAX-POL-007).';

-- =====================================================================================
-- PROPOSE_USE_TAX_ACCRUAL(document_number)
--   Deterministic: amount = SUM(tax_minor) of tax lines with treatment 'use_tax_accrual'.
--   Idempotent: returns the existing proposal if one is pending/approved; refuses if the
--   GL already has a 2410 entry for the document.  Inserts a BALANCED 2-line proposal.
-- =====================================================================================
CREATE OR REPLACE PROCEDURE HALIDE_TAX.AGENT.PROPOSE_USE_TAX_ACCRUAL(DOCUMENT_NUMBER VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Propose (never post) a use tax accrual journal for one supplier invoice. Amount comes from the tax engine lines. Creates a pending proposal that a Controller must approve.'
EXECUTE AS OWNER
AS
$$
DECLARE
  v_doc        VARCHAR;
  v_user       VARCHAR;
  v_role       VARCHAR;
  v_n_docs     INTEGER DEFAULT 0;
  v_doc_type   VARCHAR;
  v_entity     VARCHAR;
  v_currency   VARCHAR;
  v_party      VARCHAR;
  v_inv_status VARCHAR;
  v_period     VARCHAR;
  v_treatments VARCHAR;
  v_n_lines    INTEGER DEFAULT 0;
  v_tax_minor  NUMBER(38,0) DEFAULT 0;
  v_juris      VARCHAR;
  v_juris_name VARCHAR;
  v_rate       NUMBER(9,6);
  v_base_minor NUMBER(38,0);
  v_rules      VARCHAR;
  v_gl_entry   VARCHAR;
  v_existing   VARCHAR;
  v_exist_stat VARCHAR;
  v_dr_acct    VARCHAR;
  v_dr_name    VARCHAR;
  v_cr_name    VARCHAR;
  v_mpm        NUMBER(10,0);
  v_amt        NUMBER(38,2);
  v_disp       VARCHAR;
  v_pid        VARCHAR;
  v_rationale  VARCHAR;
  v_desc1      VARCHAR;
  v_desc2      VARCHAR;
  v_now        TIMESTAMP_LTZ;
BEGIN
  v_doc := UPPER(TRIM(DOCUMENT_NUMBER));
  SELECT CURRENT_USER(), CURRENT_ROLE() INTO :v_user, :v_role;

  -- 1. the document must exist and be a supplier invoice
  SELECT COUNT(*), MAX(DOC_TYPE), MAX(ENTITY_ID), MAX(CURRENCY), MAX(PARTY), MAX(STATUS),
         MAX(TO_CHAR(DOCUMENT_DATE, 'YYYY-MM')), MAX(TREATMENTS)
    INTO :v_n_docs, :v_doc_type, :v_entity, :v_currency, :v_party, :v_inv_status, :v_period, :v_treatments
    FROM HALIDE_TAX.RAW.DOCUMENTS WHERE NUMBER = :v_doc;
  IF (v_n_docs = 0 OR v_doc_type <> 'supplier_invoice') THEN
    INSERT INTO HALIDE_TAX.AGENT.AUDIT_LOG (ACTOR_USER, ACTOR_ROLE, ACTION, SOURCE_DOCUMENT, OUTCOME, DETAILS)
      SELECT :v_user, :v_role, 'PROPOSE_USE_TAX_ACCRUAL', :v_doc, 'rejected_input',
             OBJECT_CONSTRUCT('reason', 'not a supplier invoice or not found');
    RETURN OBJECT_CONSTRUCT('status', 'not_found',
      'message', 'Document ' || v_doc || ' is not a supplier invoice in HALIDE_TAX. Nothing proposed.');
  END IF;

  -- 2. deterministic amount from the tax engine lines
  SELECT COUNT(*), COALESCE(SUM(TAX_MINOR), 0), MAX(JURISDICTION_CODE), MAX(JURISDICTION_NAME),
         MAX(RATE), COALESCE(SUM(TAXABLE_BASE_MINOR), 0), LISTAGG(DISTINCT RULE_ID, ', ')
    INTO :v_n_lines, :v_tax_minor, :v_juris, :v_juris_name, :v_rate, :v_base_minor, :v_rules
    FROM HALIDE_TAX.RAW.TAX_LINES
   WHERE DOCUMENT_NUMBER = :v_doc AND TREATMENT = 'use_tax_accrual' AND ACCRUAL = TRUE;
  IF (v_n_lines = 0 OR v_tax_minor <= 0) THEN
    INSERT INTO HALIDE_TAX.AGENT.AUDIT_LOG (ACTOR_USER, ACTOR_ROLE, ACTION, SOURCE_DOCUMENT, OUTCOME, DETAILS)
      SELECT :v_user, :v_role, 'PROPOSE_USE_TAX_ACCRUAL', :v_doc, 'not_applicable',
             OBJECT_CONSTRUCT('treatment', :v_treatments);
    RETURN OBJECT_CONSTRUCT('status', 'not_applicable', 'document_number', v_doc,
      'tax_treatment', v_treatments,
      'message', 'No use_tax_accrual lines on ' || v_doc || ' (treatment: ' || v_treatments || '). Nothing proposed.');
  END IF;

  -- 3. idempotency: already accrued in the posted GL?
  SELECT MAX(ENTRY_NUMBER) INTO :v_gl_entry
    FROM HALIDE_TAX.RAW.JOURNAL_LINES
   WHERE SOURCE_DOCUMENT = :v_doc AND ACCOUNT_CODE = '2410';
  IF (v_gl_entry IS NOT NULL) THEN
    INSERT INTO HALIDE_TAX.AGENT.AUDIT_LOG (ACTOR_USER, ACTOR_ROLE, ACTION, SOURCE_DOCUMENT, OBJECT_ID, OUTCOME)
      SELECT :v_user, :v_role, 'PROPOSE_USE_TAX_ACCRUAL', :v_doc, :v_gl_entry, 'already_in_gl';
    RETURN OBJECT_CONSTRUCT('status', 'already_in_gl', 'document_number', v_doc,
      'gl_entry_number', v_gl_entry,
      'message', 'Use tax for ' || v_doc || ' is already accrued in posted GL entry ' || v_gl_entry || '. Nothing proposed.');
  END IF;

  -- 4. idempotency: already proposed (pending or approved)?
  SELECT MAX(PROPOSAL_ID), MAX(STATUS) INTO :v_existing, :v_exist_stat
    FROM HALIDE_TAX.AGENT.PROPOSED_JOURNALS
   WHERE SOURCE_DOCUMENT = :v_doc AND PROPOSAL_TYPE = 'USE_TAX_ACCRUAL'
     AND STATUS IN ('pending', 'approved');
  IF (v_existing IS NOT NULL) THEN
    INSERT INTO HALIDE_TAX.AGENT.AUDIT_LOG (ACTOR_USER, ACTOR_ROLE, ACTION, SOURCE_DOCUMENT, OBJECT_ID, OUTCOME)
      SELECT :v_user, :v_role, 'PROPOSE_USE_TAX_ACCRUAL', :v_doc, :v_existing, 'duplicate_ignored';
    RETURN OBJECT_CONSTRUCT('status', 'already_proposed', 'document_number', v_doc,
      'proposal_id', v_existing, 'proposal_status', v_exist_stat,
      'message', 'Proposal ' || v_existing || ' already exists for ' || v_doc || ' (status ' || v_exist_stat || '). No duplicate created.');
  END IF;

  -- 5. debit account = expense account used on this supplier's earlier posted invoices
  SELECT MAX(e.ACCOUNT_CODE) INTO :v_dr_acct
    FROM HALIDE_TAX.RAW.JOURNAL_LINES e
    JOIN HALIDE_TAX.RAW.JOURNAL_LINES p ON p.ENTRY_NUMBER = e.ENTRY_NUMBER AND p.LINE_TYPE = 'PAYABLE'
    JOIN HALIDE_TAX.RAW.PARTIES s       ON s.ID = p.SUPPLIER
   WHERE e.LINE_TYPE = 'EXPENSE' AND s.NAME = :v_party;
  v_dr_acct := COALESCE(v_dr_acct, '6900');
  SELECT MAX(NAME) INTO :v_dr_name FROM HALIDE_TAX.RAW.ACCOUNTS WHERE CODE = :v_dr_acct;
  SELECT MAX(NAME) INTO :v_cr_name FROM HALIDE_TAX.RAW.ACCOUNTS WHERE CODE = '2410';

  -- 6. major-unit amount + display string
  SELECT MAX(MINOR_PER_MAJOR) INTO :v_mpm FROM HALIDE_TAX.CORE.CURRENCIES WHERE CURRENCY = :v_currency;
  v_amt  := (v_tax_minor / v_mpm)::NUMBER(38,2);
  v_disp := v_currency || ' ' || IFF(v_mpm = 1, TO_VARCHAR(v_amt, 'FM999,999,999,990'),
                                                TO_VARCHAR(v_amt, 'FM999,999,999,990.00'));
  v_rationale := 'Vendor ' || v_party || ' charged no sales tax on a purchase taxable in ' || v_juris_name ||
                 ' (rule ' || v_rules || ', combined rate ' || TO_VARCHAR(v_rate * 100, 'FM990.000') ||
                 '%). Use tax is owed by Halide Labs and accrued per HL-TAX-POL-001.';
  v_desc1 := 'Use tax on ' || v_doc || ' (' || v_party || ') - ' || v_juris_name;
  v_desc2 := 'use_tax_accrual ' || v_juris || ' self-assessed - ' || v_doc;
  SELECT CURRENT_TIMESTAMP() INTO :v_now;

  -- 7. insert a balanced, PENDING proposal
  SELECT 'PJ-' || LPAD(TO_VARCHAR(HALIDE_TAX.AGENT.PROPOSAL_SEQ.NEXTVAL), 5, '0') INTO :v_pid;

  INSERT INTO HALIDE_TAX.AGENT.PROPOSED_JOURNALS
    (PROPOSAL_ID, PROPOSAL_TYPE, SOURCE_DOCUMENT, ENTITY_ID, SUPPLIER_NAME, CURRENCY, CLOSE_PERIOD,
     TOTAL_MINOR, TOTAL_AMOUNT, AMOUNT_DISPLAY, STATUS, POLICY_ID, RULE_IDS, RATIONALE,
     PROPOSED_BY_USER, PROPOSED_BY_ROLE, PROPOSED_AT)
  VALUES
    (:v_pid, 'USE_TAX_ACCRUAL', :v_doc, :v_entity, :v_party, :v_currency, :v_period,
     :v_tax_minor, :v_amt, :v_disp, 'pending', 'HL-TAX-POL-001', :v_rules, :v_rationale,
     :v_user, :v_role, :v_now);

  INSERT INTO HALIDE_TAX.AGENT.PROPOSED_JOURNAL_LINES
    (PROPOSAL_ID, LINE_NO, ACCOUNT_CODE, ACCOUNT_NAME, DEBIT_MINOR, CREDIT_MINOR,
     DEBIT_AMOUNT, CREDIT_AMOUNT, CURRENCY, TAX_JURISDICTION, DESCRIPTION)
  VALUES
    (:v_pid, 1, :v_dr_acct, :v_dr_name, :v_tax_minor, 0, :v_amt, 0, :v_currency, :v_juris, :v_desc1),
    (:v_pid, 2, '2410', :v_cr_name, 0, :v_tax_minor, 0, :v_amt, :v_currency, :v_juris, :v_desc2);

  INSERT INTO HALIDE_TAX.AGENT.AUDIT_LOG (ACTOR_USER, ACTOR_ROLE, ACTION, SOURCE_DOCUMENT, OBJECT_ID, OUTCOME, DETAILS)
    SELECT :v_user, :v_role, 'PROPOSE_USE_TAX_ACCRUAL', :v_doc, :v_pid, 'proposed',
           OBJECT_CONSTRUCT('amount_minor', :v_tax_minor, 'currency', :v_currency,
                            'debit', :v_dr_acct, 'credit', '2410', 'rules', :v_rules);

  RETURN OBJECT_CONSTRUCT(
    'status', 'proposed',
    'proposal_id', v_pid,
    'proposal_status', 'pending',
    'document_number', v_doc,
    'supplier', v_party,
    'entity_id', v_entity,
    'close_period', v_period,
    'jurisdiction', v_juris_name,
    'rate', v_rate,
    'amount', v_amt,
    'currency', v_currency,
    'amount_display', v_disp,
    'journal_lines', ARRAY_CONSTRUCT(
        OBJECT_CONSTRUCT('line', 1, 'account', v_dr_acct || ' ' || v_dr_name, 'debit', v_disp),
        OBJECT_CONSTRUCT('line', 2, 'account', '2410 ' || v_cr_name, 'credit', v_disp)),
    'policy', 'HL-TAX-POL-001 Use Tax Accrual Policy',
    'next_step', 'PENDING Controller approval (HL-TAX-POL-004). NOT posted to the ledger.');
END;
$$;

-- =====================================================================================
-- FLAG_VENDOR_OVERCHARGE(document_number, note)
--   overcharge = vendor-charged tax - (taxable base x rate) on lines with treatment 'overcharged'
-- =====================================================================================
CREATE OR REPLACE PROCEDURE HALIDE_TAX.AGENT.FLAG_VENDOR_OVERCHARGE(DOCUMENT_NUMBER VARCHAR, NOTE VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Flag a vendor sales-tax overcharge on a supplier invoice for credit memo / refund (HL-TAX-POL-002). Does not change the invoice, the hold, or any payment.'
EXECUTE AS OWNER
AS
$$
DECLARE
  v_doc       VARCHAR;
  v_note      VARCHAR;
  v_user      VARCHAR;
  v_role      VARCHAR;
  v_n_lines   INTEGER DEFAULT 0;
  v_over      NUMBER(38,0) DEFAULT 0;
  v_juris     VARCHAR;
  v_entity    VARCHAR;
  v_currency  VARCHAR;
  v_party     VARCHAR;
  v_inv_stat  VARCHAR;
  v_existing  VARCHAR;
  v_mpm       NUMBER(10,0);
  v_amt       NUMBER(38,2);
  v_disp      VARCHAR;
  v_fid       VARCHAR;
  v_action    VARCHAR;
  v_now       TIMESTAMP_LTZ;
BEGIN
  v_doc  := UPPER(TRIM(DOCUMENT_NUMBER));
  v_note := LEFT(COALESCE(NOTE, ''), 2000);
  SELECT CURRENT_USER(), CURRENT_ROLE() INTO :v_user, :v_role;

  SELECT COUNT(*),
         COALESCE(SUM(COALESCE(t.VENDOR_CHARGED_MINOR, t.TAX_MINOR) - ROUND(t.TAXABLE_BASE_MINOR * t.RATE)), 0),
         MAX(t.JURISDICTION_NAME), MAX(d.ENTITY_ID), MAX(d.CURRENCY), MAX(d.PARTY), MAX(d.STATUS)
    INTO :v_n_lines, :v_over, :v_juris, :v_entity, :v_currency, :v_party, :v_inv_stat
    FROM HALIDE_TAX.RAW.TAX_LINES t
    JOIN HALIDE_TAX.RAW.DOCUMENTS d ON d.NUMBER = t.DOCUMENT_NUMBER
   WHERE t.DOCUMENT_NUMBER = :v_doc AND t.TREATMENT = 'overcharged'
     AND d.DOC_TYPE = 'supplier_invoice';
  IF (v_n_lines = 0 OR v_over <= 0) THEN
    INSERT INTO HALIDE_TAX.AGENT.AUDIT_LOG (ACTOR_USER, ACTOR_ROLE, ACTION, SOURCE_DOCUMENT, OUTCOME)
      SELECT :v_user, :v_role, 'FLAG_VENDOR_OVERCHARGE', :v_doc, 'not_applicable';
    RETURN OBJECT_CONSTRUCT('status', 'not_applicable', 'document_number', v_doc,
      'message', 'No vendor overcharge found on ' || v_doc || '. Nothing flagged.');
  END IF;

  SELECT MAX(FLAG_ID) INTO :v_existing FROM HALIDE_TAX.AGENT.VENDOR_TAX_FLAGS
   WHERE SOURCE_DOCUMENT = :v_doc AND STATUS = 'open';
  IF (v_existing IS NOT NULL) THEN
    INSERT INTO HALIDE_TAX.AGENT.AUDIT_LOG (ACTOR_USER, ACTOR_ROLE, ACTION, SOURCE_DOCUMENT, OBJECT_ID, OUTCOME)
      SELECT :v_user, :v_role, 'FLAG_VENDOR_OVERCHARGE', :v_doc, :v_existing, 'duplicate_ignored';
    RETURN OBJECT_CONSTRUCT('status', 'already_flagged', 'flag_id', v_existing, 'document_number', v_doc,
      'message', 'Open flag ' || v_existing || ' already exists for ' || v_doc || '.');
  END IF;

  SELECT MAX(MINOR_PER_MAJOR) INTO :v_mpm FROM HALIDE_TAX.CORE.CURRENCIES WHERE CURRENCY = :v_currency;
  v_amt  := (v_over / v_mpm)::NUMBER(38,2);
  v_disp := v_currency || ' ' || IFF(v_mpm = 1, TO_VARCHAR(v_amt, 'FM999,999,999,990'),
                                                TO_VARCHAR(v_amt, 'FM999,999,999,990.00'));
  v_action := 'Keep tax portion on hold; AP to request a corrected invoice or credit memo from ' || v_party ||
              ' within 5 business days; escalate per HL-TAX-POL-002 thresholds' ||
              IFF(v_amt >= 100000 AND v_currency = 'USD', ' (>= USD 100,000: notify Controller and CFO).',
                  IFF(v_amt >= 10000 AND v_currency = 'USD', ' (>= USD 10,000: notify Controller).', '.'));

  SELECT 'VF-' || LPAD(TO_VARCHAR(HALIDE_TAX.AGENT.FLAG_SEQ.NEXTVAL), 5, '0'), CURRENT_TIMESTAMP()
    INTO :v_fid, :v_now;

  INSERT INTO HALIDE_TAX.AGENT.VENDOR_TAX_FLAGS
    (FLAG_ID, SOURCE_DOCUMENT, ENTITY_ID, SUPPLIER_NAME, CURRENCY, OVERCHARGE_MINOR, OVERCHARGE_AMOUNT,
     AMOUNT_DISPLAY, TAX_JURISDICTION, RECOMMENDED_ACTION, NOTE, STATUS, POLICY_ID,
     FLAGGED_BY_USER, FLAGGED_BY_ROLE, FLAGGED_AT)
  VALUES
    (:v_fid, :v_doc, :v_entity, :v_party, :v_currency, :v_over, :v_amt,
     :v_disp, :v_juris, :v_action, :v_note, 'open', 'HL-TAX-POL-002',
     :v_user, :v_role, :v_now);

  INSERT INTO HALIDE_TAX.AGENT.AUDIT_LOG (ACTOR_USER, ACTOR_ROLE, ACTION, SOURCE_DOCUMENT, OBJECT_ID, OUTCOME, DETAILS)
    SELECT :v_user, :v_role, 'FLAG_VENDOR_OVERCHARGE', :v_doc, :v_fid, 'flagged',
           OBJECT_CONSTRUCT('overcharge_minor', :v_over, 'currency', :v_currency, 'note', :v_note);

  RETURN OBJECT_CONSTRUCT('status', 'flagged', 'flag_id', v_fid, 'document_number', v_doc,
    'supplier', v_party, 'invoice_status', v_inv_stat, 'jurisdiction', v_juris,
    'overcharge_amount', v_amt, 'currency', v_currency, 'amount_display', v_disp,
    'recommended_action', v_action,
    'policy', 'HL-TAX-POL-002 Vendor Tax Overcharge and Refund Procedure',
    'next_step', 'Flag recorded. No payment, hold or ledger entry was changed.');
END;
$$;

-- =====================================================================================
-- APPROVE_PROPOSAL / REJECT_PROPOSAL  — CONTROLLER ONLY (see grants below)
-- =====================================================================================
CREATE OR REPLACE PROCEDURE HALIDE_TAX.AGENT.APPROVE_PROPOSAL(PROPOSAL_ID VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Controller approval of a pending tax journal proposal (maker-checker, balance check). Approval queues it for ERP posting; it does not post.'
EXECUTE AS OWNER
AS
$$
DECLARE
  v_pid     VARCHAR;
  v_user    VARCHAR;
  v_role    VARCHAR;
  v_status  VARCHAR;
  v_maker   VARCHAR;
  v_doc     VARCHAR;
  v_disp    VARCHAR;
  v_n       INTEGER DEFAULT 0;
  v_dr      NUMBER(38,0) DEFAULT 0;
  v_cr      NUMBER(38,0) DEFAULT 0;
BEGIN
  v_pid := UPPER(TRIM(PROPOSAL_ID));
  SELECT CURRENT_USER(), CURRENT_ROLE() INTO :v_user, :v_role;

  SELECT COUNT(*), MAX(STATUS), MAX(PROPOSED_BY_USER), MAX(SOURCE_DOCUMENT), MAX(AMOUNT_DISPLAY)
    INTO :v_n, :v_status, :v_maker, :v_doc, :v_disp
    FROM HALIDE_TAX.AGENT.PROPOSED_JOURNALS WHERE PROPOSAL_ID = :v_pid;
  IF (v_n = 0) THEN
    RETURN OBJECT_CONSTRUCT('status', 'not_found', 'proposal_id', v_pid);
  END IF;
  IF (v_status <> 'pending') THEN
    RETURN OBJECT_CONSTRUCT('status', 'not_pending', 'proposal_id', v_pid, 'current_status', v_status);
  END IF;
  IF (v_maker = v_user) THEN
    INSERT INTO HALIDE_TAX.AGENT.AUDIT_LOG (ACTOR_USER, ACTOR_ROLE, ACTION, SOURCE_DOCUMENT, OBJECT_ID, OUTCOME)
      SELECT :v_user, :v_role, 'APPROVE_PROPOSAL', :v_doc, :v_pid, 'blocked_maker_checker';
    RETURN OBJECT_CONSTRUCT('status', 'blocked', 'proposal_id', v_pid,
      'message', 'Maker-checker: ' || v_user || ' prepared this proposal and cannot approve it (HL-TAX-POL-004).');
  END IF;

  SELECT COALESCE(SUM(DEBIT_MINOR), 0), COALESCE(SUM(CREDIT_MINOR), 0) INTO :v_dr, :v_cr
    FROM HALIDE_TAX.AGENT.PROPOSED_JOURNAL_LINES WHERE PROPOSAL_ID = :v_pid;
  IF (v_dr <> v_cr OR v_dr = 0) THEN
    RETURN OBJECT_CONSTRUCT('status', 'blocked', 'proposal_id', v_pid, 'message', 'Entry is not balanced.');
  END IF;

  UPDATE HALIDE_TAX.AGENT.PROPOSED_JOURNALS
     SET STATUS = 'approved', DECIDED_BY_USER = :v_user, DECIDED_AT = CURRENT_TIMESTAMP(),
         DECISION_COMMENT = 'Approved'
   WHERE PROPOSAL_ID = :v_pid AND STATUS = 'pending';

  INSERT INTO HALIDE_TAX.AGENT.AUDIT_LOG (ACTOR_USER, ACTOR_ROLE, ACTION, SOURCE_DOCUMENT, OBJECT_ID, OUTCOME)
    SELECT :v_user, :v_role, 'APPROVE_PROPOSAL', :v_doc, :v_pid, 'approved';

  RETURN OBJECT_CONSTRUCT('status', 'approved', 'proposal_id', v_pid, 'document_number', v_doc,
    'amount_display', v_disp, 'approved_by', v_user,
    'next_step', 'Queued in AGENT.APPROVED_FOR_POSTING for ERP posting.');
END;
$$;

CREATE OR REPLACE PROCEDURE HALIDE_TAX.AGENT.REJECT_PROPOSAL(PROPOSAL_ID VARCHAR, REASON VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  v_pid VARCHAR; v_user VARCHAR; v_role VARCHAR; v_status VARCHAR; v_doc VARCHAR;
BEGIN
  v_pid := UPPER(TRIM(PROPOSAL_ID));
  SELECT CURRENT_USER(), CURRENT_ROLE() INTO :v_user, :v_role;
  SELECT MAX(STATUS), MAX(SOURCE_DOCUMENT) INTO :v_status, :v_doc
    FROM HALIDE_TAX.AGENT.PROPOSED_JOURNALS WHERE PROPOSAL_ID = :v_pid;
  IF (v_status IS NULL OR v_status <> 'pending') THEN
    RETURN OBJECT_CONSTRUCT('status', 'not_pending', 'proposal_id', v_pid, 'current_status', v_status);
  END IF;
  UPDATE HALIDE_TAX.AGENT.PROPOSED_JOURNALS
     SET STATUS = 'rejected', DECIDED_BY_USER = :v_user, DECIDED_AT = CURRENT_TIMESTAMP(),
         DECISION_COMMENT = :REASON
   WHERE PROPOSAL_ID = :v_pid;
  INSERT INTO HALIDE_TAX.AGENT.AUDIT_LOG (ACTOR_USER, ACTOR_ROLE, ACTION, SOURCE_DOCUMENT, OBJECT_ID, OUTCOME, DETAILS)
    SELECT :v_user, :v_role, 'REJECT_PROPOSAL', :v_doc, :v_pid, 'rejected', OBJECT_CONSTRUCT('reason', :REASON);
  RETURN OBJECT_CONSTRUCT('status', 'rejected', 'proposal_id', v_pid);
END;
$$;

-- ---------- views for the close desk -------------------------------------------------
CREATE OR REPLACE VIEW HALIDE_TAX.AGENT.CLOSE_DESK
  COMMENT = 'Supplier-invoice tax worklist with proposal and flag status. One row per supplier invoice.'
AS
SELECT si.*,
       pj.PROPOSAL_ID, pj.STATUS AS PROPOSAL_STATUS, pj.PROPOSED_BY_USER, pj.DECIDED_BY_USER,
       vf.FLAG_ID, vf.STATUS AS FLAG_STATUS,
       CASE
         WHEN si.CLOSE_ACTION = 'ACCRUE_USE_TAX'   AND pj.PROPOSAL_ID IS NULL THEN 'TO DO: propose accrual'
         WHEN si.CLOSE_ACTION = 'ACCRUE_USE_TAX'   AND pj.STATUS = 'pending'  THEN 'WAITING: Controller approval'
         WHEN si.CLOSE_ACTION = 'ACCRUE_USE_TAX'   AND pj.STATUS = 'approved' THEN 'DONE: approved, awaiting ERP posting'
         WHEN si.CLOSE_ACTION = 'VENDOR_OVERCHARGE' AND vf.FLAG_ID IS NULL     THEN 'TO DO: flag overcharge'
         WHEN si.CLOSE_ACTION = 'VENDOR_OVERCHARGE'                           THEN 'DONE: flagged, refund requested'
         ELSE 'NO ACTION'
       END AS DESK_STATUS
FROM HALIDE_TAX.CORE.SUPPLIER_INVOICES si
LEFT JOIN HALIDE_TAX.AGENT.PROPOSED_JOURNALS pj
       ON pj.SOURCE_DOCUMENT = si.DOCUMENT_NUMBER AND pj.STATUS IN ('pending','approved')
LEFT JOIN HALIDE_TAX.AGENT.VENDOR_TAX_FLAGS vf
       ON vf.SOURCE_DOCUMENT = si.DOCUMENT_NUMBER AND vf.STATUS = 'open';

CREATE OR REPLACE VIEW HALIDE_TAX.AGENT.APPROVED_FOR_POSTING
  COMMENT = 'Approved, not yet exported proposals: the hand-off to the ERP. The tax desk never posts.'
AS
SELECT h.PROPOSAL_ID, h.SOURCE_DOCUMENT, h.ENTITY_ID, h.CURRENCY, h.CLOSE_PERIOD, h.DECIDED_BY_USER,
       l.LINE_NO, l.ACCOUNT_CODE, l.ACCOUNT_NAME, l.DEBIT_MINOR, l.CREDIT_MINOR, l.DESCRIPTION
FROM HALIDE_TAX.AGENT.PROPOSED_JOURNALS h
JOIN HALIDE_TAX.AGENT.PROPOSED_JOURNAL_LINES l ON l.PROPOSAL_ID = h.PROPOSAL_ID
WHERE h.STATUS = 'approved' AND NOT h.EXPORTED_TO_ERP;

-- ---------- grants (least privilege) -------------------------------------------------
-- read: views only (RAW stays private to HALIDE_BUILDER)
GRANT SELECT ON ALL VIEWS  IN SCHEMA HALIDE_TAX.CORE  TO ROLE TAX_AGENT;
GRANT SELECT ON ALL TABLES IN SCHEMA HALIDE_TAX.CORE  TO ROLE TAX_AGENT;   -- CURRENCIES
GRANT SELECT ON ALL VIEWS  IN SCHEMA HALIDE_TAX.AGENT TO ROLE TAX_AGENT;
GRANT SELECT ON TABLE HALIDE_TAX.AGENT.PROPOSED_JOURNALS      TO ROLE TAX_AGENT;
GRANT SELECT ON TABLE HALIDE_TAX.AGENT.PROPOSED_JOURNAL_LINES TO ROLE TAX_AGENT;
GRANT SELECT ON TABLE HALIDE_TAX.AGENT.VENDOR_TAX_FLAGS       TO ROLE TAX_AGENT;
GRANT SELECT ON TABLE HALIDE_TAX.AGENT.AUDIT_LOG              TO ROLE TAX_ANALYST;
-- write: ONLY via procedures. No INSERT/UPDATE/DELETE grants to anyone.
GRANT USAGE ON PROCEDURE HALIDE_TAX.AGENT.PROPOSE_USE_TAX_ACCRUAL(VARCHAR)         TO ROLE TAX_AGENT;
GRANT USAGE ON PROCEDURE HALIDE_TAX.AGENT.FLAG_VENDOR_OVERCHARGE(VARCHAR, VARCHAR) TO ROLE TAX_AGENT;
GRANT USAGE ON PROCEDURE HALIDE_TAX.AGENT.APPROVE_PROPOSAL(VARCHAR)                TO ROLE CONTROLLER;
GRANT USAGE ON PROCEDURE HALIDE_TAX.AGENT.REJECT_PROPOSAL(VARCHAR, VARCHAR)        TO ROLE CONTROLLER;
-- (TAX_AGENT -> TAX_ANALYST -> CONTROLLER hierarchy is set in 00_setup.sql, so CONTROLLER
--  can also propose/flag; maker-checker still stops self-approval.)

-- ---------- smoke test (run as an analyst, then as a controller) ---------------------
-- ⚠ USE SECONDARY ROLES NONE first: users default to secondary roles ALL, which would give your
--   TAX_ANALYST session CONTROLLER's grants too and hide the SoD error.
-- USE SECONDARY ROLES NONE;
-- USE ROLE TAX_ANALYST;
-- CALL HALIDE_TAX.AGENT.PROPOSE_USE_TAX_ACCRUAL('SINV-US-2026-000012');
--   -> status 'proposed', amount_display 'USD 3,465.00', lines 6100 Dr / 2410 Cr
-- CALL HALIDE_TAX.AGENT.PROPOSE_USE_TAX_ACCRUAL('SINV-US-2026-000012');   -> 'already_proposed'
-- CALL HALIDE_TAX.AGENT.PROPOSE_USE_TAX_ACCRUAL('SINV-US-2026-000008');   -> 'already_in_gl' (US-RE-2026-000008)
-- CALL HALIDE_TAX.AGENT.PROPOSE_USE_TAX_ACCRUAL('SINV-JP-2026-000005');   -> 'not_applicable'
-- CALL HALIDE_TAX.AGENT.FLAG_VENDOR_OVERCHARGE('SINV-US-2026-000013', 'CA compute services not taxable per engine');
--   -> 'flagged', 'USD 103,500.00'
-- CALL HALIDE_TAX.AGENT.APPROVE_PROPOSAL('PJ-00001');  -> ERROR insufficient privileges (good: SoD)
-- USE ROLE CONTROLLER;
-- CALL HALIDE_TAX.AGENT.APPROVE_PROPOSAL('PJ-00001');  -> 'approved' (or 'blocked' maker-checker if same user)
-- SELECT * FROM HALIDE_TAX.AGENT.CLOSE_DESK WHERE DESK_STATUS <> 'NO ACTION';
-- SELECT * FROM HALIDE_TAX.AGENT.AUDIT_LOG ORDER BY EVENT_ID;
-- NOTE for a solo demo: you are ONE user, so maker-checker will block you approving your own
-- proposal. Either (a) let the AGENT propose via the MCP service user HALIDE_AGENT_SVC (00_setup)
-- so PROPOSED_BY_USER = HALIDE_AGENT_SVC, then approve as yourself; or (b) show the 'blocked'
-- message as the control working.
