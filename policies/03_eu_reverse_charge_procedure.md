# EU Reverse-Charge and Acquisition VAT Procedure (Ireland)

**Halide Labs — Internal Tax Procedure** · Policy ID: HL-TAX-POL-003 · Owner: Senior Manager, Tax · Entity: Halide Labs Ireland Limited (IE) · Effective: 1 July 2026 · Version 1.2

> FICTIONAL COMPANY POLICY FOR DEMO PURPOSES. Halide Labs is a fictional company. This memo is not tax advice.

## 1. Purpose

Halide Labs Ireland (VAT number on file in the registrations table) buys services and goods from suppliers outside Ireland. In general under EU VAT rules, when a business customer receives services from a supplier established outside the customer's member state, the **customer accounts for the VAT itself (reverse charge)**, and when a business acquires goods dispatched from another member state it accounts for **acquisition VAT**. The supplier's invoice therefore shows no Irish VAT, and Halide Labs Ireland self-assesses it.

## 2. Rules in the engine

| Rule ID | Situation | Treatment |
|---|---|---|
| `IE-P-RC-NONEU-SERVICES` | services from a supplier outside the EU (e.g. UK tax advisory) | `reverse_charge` |
| `IE-P-ICA-GOODS` | goods dispatched from another EU member state (e.g. data center equipment from Germany) | `acquisition_vat` |
| `IE-P-DOMESTIC` | Irish supplier charging Irish VAT | `vendor_charged` |

The self-assessed amount = taxable base × the Irish standard rate in the rate table (jurisdiction `IE`).

## 3. Accounting entry

For both reverse charge and acquisition VAT, the entry has two tax legs that offset for a fully taxable business:

| Account | Debit | Credit |
|---|---|---|
| 1400 Input VAT recoverable | VAT amount | |
| 2420 Self-assessed VAT and GST payable | | VAT amount |

The expense or asset is booked at the net amount and the supplier is paid the net amount.

## 4. Controls

- The supplier's VAT number (where applicable) must be on file and validated before the reverse charge is applied.
- The invoice must not show Irish VAT. If it does, treat it as a possible overcharge under HL-TAX-POL-002.
- Self-assessed VAT is reported on the VAT return for the period of the invoice; the 2420 balance is reconciled to the return each period.
- Entries follow the approval matrix in HL-TAX-POL-004.
