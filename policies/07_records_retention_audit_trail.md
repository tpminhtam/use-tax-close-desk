# Tax Records Retention and Audit Trail

**Halide Labs — Internal Policy** · Policy ID: HL-TAX-POL-007 · Owner: Controller, with Senior Manager, Tax · Effective: 1 July 2026 · Version 1.0

> FICTIONAL COMPANY POLICY FOR DEMO PURPOSES. Halide Labs is a fictional company. Retention periods here are company standards, not statements of law.

## 1. What is kept

| Record | Where | Company retention standard |
|---|---|---|
| Supplier and customer invoices | ERP document store | 7 years after the end of the fiscal year |
| Tax determination lines (rule ID, rate, base, treatment) | tax data warehouse | 7 years |
| Proposed tax journals, approvals and rejections | close desk (AGENT schema) | 7 years |
| Audit log of every proposal, flag and approval, including those by the AI assistant | AGENT.AUDIT_LOG | 7 years |
| AI assistant conversations and traces | agent monitoring / observability | 1 year, or longer if linked to an approved entry |
| Exemption certificates and registrations | tax data warehouse | life of certificate + 7 years |

Tax may extend any period while an audit, inquiry or refund claim is open in a jurisdiction. Where local law requires longer retention, the longer period applies.

## 2. Audit trail requirements

- Every tax journal proposal records: preparer (user and role), time, source document, amounts in minor units and currency, rule IDs used, and the policy cited.
- Every approval or rejection records the approver, time and comment. A record is never edited after approval; corrections are new proposals.
- AI-assisted work is labelled as such in the audit log so a reviewer can tell which proposals an AI assistant prepared.

## 3. Deletion

Records past retention are deleted only after Tax confirms there is no open audit, inquiry or refund claim for the period.
