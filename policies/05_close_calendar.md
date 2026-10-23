# Indirect Tax Month-End Close Calendar

**Halide Labs — Internal Tax Procedure** · Policy ID: HL-TAX-POL-005 · Owner: Senior Manager, Tax · Effective: 1 July 2026 · Version 1.3

> FICTIONAL COMPANY POLICY FOR DEMO PURPOSES. Halide Labs is a fictional company.

## 1. Purpose

Sets the order and deadlines for indirect tax work in each monthly close, for all four entities (US, IE, JP, SG). BD = business day of the following month.

## 2. Calendar

| When | Step | Owner | Output |
|---|---|---|---|
| BD-2 | Supplier invoice cut-off: invoices received by this date are in the period | AP | invoice list |
| BD+1 | Run the supplier-invoice tax review (close desk worklist) | Tax Analyst / AI assistant | worklist by close action |
| BD+1 | Propose use tax accruals for every `ACCRUE_USE_TAX` item (HL-TAX-POL-001) | Tax Analyst / AI assistant | pending proposals |
| BD+1 | Flag every `VENDOR_OVERCHARGE` item and place the invoice on hold (HL-TAX-POL-002) | Tax Analyst / AP | vendor tax flags |
| BD+2 | Confirm reverse-charge and acquisition VAT entries for IE (HL-TAX-POL-003) | Tax Analyst | reviewed list |
| BD+3 | Controller approves or rejects all pending proposals (HL-TAX-POL-004) | Controller | approved proposals |
| BD+3 | Export approved proposals to the ERP posting queue | ERP posting service | posted entries |
| BD+4 | Reconcile 2410 US use tax payable and 2420 self-assessed VAT payable | Tax Analyst | reconciliation |
| BD+5 | Tax sign-off on the period | Senior Manager, Tax | sign-off |

## 3. Rules

- A period may not be signed off while any `ACCRUE_USE_TAX` item has no approved proposal, or any `VENDOR_OVERCHARGE` item has no open flag.
- Items found after BD+3 are accrued in the next period and noted in the sign-off memo.
- Filing deadlines for returns follow each jurisdiction's rules and are tracked separately in the filing calendar.
