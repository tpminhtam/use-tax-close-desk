# Use Tax Accrual Policy

**Halide Labs — Internal Tax Policy** · Policy ID: HL-TAX-POL-001 · Owner: Senior Manager, Tax (Priya Raman) · Effective: 1 July 2026 · Version 2.1

> FICTIONAL COMPANY POLICY FOR DEMO PURPOSES. Halide Labs is a fictional company. This memo is not tax advice.

## 1. Purpose

Halide Labs, PBC (entity US) buys software, equipment and services from vendors across the United States. When a vendor does not charge sales tax on a purchase that is taxable where Halide Labs uses it, the obligation does not go away: in general, the buyer owes **use tax** on that purchase and must self-assess and remit it. This policy sets how the tax team identifies those purchases and accrues the liability at month-end close.

## 2. Scope

All supplier invoices booked to entity **US** with a US sales and use tax (regime `US_SUT`) determination. Non-US entities (IE, JP, SG) follow HL-TAX-POL-003 or local procedures.

## 3. How a purchase is flagged

The tax engine evaluates every supplier invoice line against the purchase rule set. For domestic US purchases the governing rule is **`US-P-DOMESTIC`**. A line is given treatment **`use_tax_accrual`** when all three are true:

1. the item is taxable in the ship-to / use jurisdiction (for example Austin, Texas — jurisdiction `US-TX-AUSTIN`);
2. Halide Labs holds no exemption certificate covering the purchase (see HL-TAX-POL-006); and
3. the vendor charged **no** sales tax on the line (vendor-charged amount = 0).

The accrual amount is **taxable base × combined rate** for the jurisdiction from the effective-dated rate table (state + city + district components). The amount is computed by the engine and stored on the tax line; **nobody, human or AI, re-keys or estimates it.**

Purchases from foreign vendors of services classified `out_of_scope` under rule `US-P-IMPORT-SERVICES` are not accrued under this policy; Tax reviews that classification quarterly.

## 4. Accounting entry

For each invoice with a use tax accrual, the proposed entry is:

| Line | Account | Debit | Credit |
|---|---|---|---|
| 1 | Expense account of the underlying purchase (e.g. 6100 Software and SaaS) | use tax amount | |
| 2 | **2410 US use tax payable** | | use tax amount |

Use tax is a cost of the purchase, so it is charged to the same expense line as the purchase. Account 2410 is a *restricted* account: entries are posted only through approved tax journals (HL-TAX-POL-004).

## 5. Timing

Use tax is accrued in the period of the invoice date, at month-end close, per the close calendar (HL-TAX-POL-005). Invoices still in `pending_approval` at cut-off are accrued if the goods or services have been received.

## 6. Controls

- One accrual per invoice. If account 2410 already carries an entry for the source document, no new accrual is proposed.
- Every accrual is proposed with status **pending** and requires Controller approval before it can be exported to the ledger.
- The preparer of a proposal may not approve it.
- Accrued use tax is reconciled to the filed returns quarterly.
