# Vendor Tax Overcharge and Refund Procedure

**Halide Labs — Internal Tax Procedure** · Policy ID: HL-TAX-POL-002 · Owner: Senior Manager, Tax · Co-owner: Accounts Payable · Effective: 1 July 2026 · Version 1.4

> FICTIONAL COMPANY POLICY FOR DEMO PURPOSES. Halide Labs is a fictional company. This memo is not tax advice.

## 1. Purpose

Vendors sometimes charge sales tax that is not due, for example on a service that is not taxable in the jurisdiction, or at the wrong rate. Paying it is a cash loss. In general, when a vendor collects sales tax in error, the buyer's first route to recover it is the **vendor** (a corrected invoice or credit memo), because the vendor is the party that remitted it. This procedure sets how Halide Labs detects, holds and recovers over-charged tax.

## 2. Detection

The tax engine compares the tax the vendor charged with the tax that should apply (taxable base × rate under rule **`US-P-DOMESTIC`** or the relevant purchase rule). A line receives treatment **`overcharged`** when the vendor-charged amount exceeds the expected tax. The **overcharge amount = vendor-charged tax − expected tax.** When the item is not taxable the expected tax is zero and the whole charged amount is the overcharge.

## 3. Steps

1. **Hold.** AP places the invoice `on_hold`. The non-tax portion may be released for payment by the Controller; the tax portion stays on hold.
2. **Flag.** Tax records a vendor tax flag with the document number, the overcharge amount in invoice currency, and the recommended action. Flags are recorded in the close desk (AGENT.VENDOR_TAX_FLAGS); an AI assistant may create a flag but may not release a hold or change a payment.
3. **Request.** AP asks the vendor for a corrected invoice or credit memo within **5 business days** of the flag.
4. **Escalate.** If the vendor refuses or does not respond within 30 days, Tax decides whether to pursue a refund claim with the taxing authority. That decision is Tax's alone and is documented.
5. **Close.** When the corrected invoice or credit memo arrives, AP releases the hold and Tax closes the flag with a reference to the credit document.

## 4. Thresholds

| Overcharge (USD equivalent) | Who is notified |
|---|---|
| under 10,000 | AP Specialist and Senior Manager, Tax |
| 10,000 and above | also the Controller |
| 100,000 and above | also the CFO, and the vendor relationship owner |

## 5. What not to do

- Do not book the over-charged tax to expense.
- Do not short-pay an invoice without telling the vendor in writing.
- Do not net an overcharge against an unrelated invoice.
