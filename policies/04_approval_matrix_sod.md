# Tax Journal Approval Matrix and Segregation of Duties

**Halide Labs — Internal Control Policy** · Policy ID: HL-TAX-POL-004 · Owner: Controller (Daniel Okafor) · Effective: 1 July 2026 · Version 3.0

> FICTIONAL COMPANY POLICY FOR DEMO PURPOSES. Halide Labs is a fictional company.

## 1. Principle

No single person or system may both **create** and **approve** a tax journal entry. Approval authority is enforced by system permissions (database roles and grants), not by instructions to people or to software.

## 2. Roles

| Role | Who | May | May not |
|---|---|---|---|
| Tax AI assistant (role TAX_AGENT) | Claude, running as a Cortex Agent | read tax data and policies; **propose** use tax accruals; **flag** vendor overcharges | approve, post, release holds, change rates or rules |
| Tax Analyst (role TAX_ANALYST) | Tax team, e.g. Priya Raman, Tam Tran | everything the assistant may do; review proposals | approve or post |
| Controller (role CONTROLLER) | Daniel Okafor | approve or reject proposals | approve a proposal he prepared himself |
| ERP posting service | myERP | post approved entries to the ledger | — |

## 3. Approval matrix (amounts in USD equivalent)

| Entry type | Under 10,000 | 10,000 – 99,999 | 100,000 and above |
|---|---|---|---|
| Use tax accrual (HL-TAX-POL-001) | Controller | Controller | Controller + Senior Manager, Tax |
| Reverse-charge / acquisition VAT (HL-TAX-POL-003) | Controller | Controller | Controller + Senior Manager, Tax |
| Vendor overcharge flag (HL-TAX-POL-002) | no approval to flag; hold release by Controller | same | same, CFO notified |

## 4. Rules

1. **Propose, never post.** An AI assistant may create proposals with status `pending` only. Approved proposals are exported to the ERP for posting; nothing is posted from the tax desk.
2. **Maker–checker.** The approver must be a different user from the preparer.
3. **Deterministic amounts.** Proposal amounts come from the tax engine's tax lines; they are not typed in by the preparer.
4. **Balanced entries.** Total debits must equal total credits before a proposal can be approved.
5. **Audit trail.** Every proposal, flag, approval and rejection writes an audit-log row with user, role, time and outcome.
6. **Restricted accounts.** Accounts 2410, 2420 and 1400 accept entries only through approved tax journals.

## 5. Access reviews

The Controller reviews membership of CONTROLLER, TAX_ANALYST and TAX_AGENT roles quarterly. Programmatic tokens used by the AI assistant are restricted to the TAX_AGENT role and expire within 90 days.
