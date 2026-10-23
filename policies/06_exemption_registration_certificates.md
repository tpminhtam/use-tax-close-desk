# Vendor Tax Exemption and Registration Certificates

**Halide Labs — Internal Tax Procedure** · Policy ID: HL-TAX-POL-006 · Owner: Senior Manager, Tax · Effective: 1 July 2026 · Version 1.1

> FICTIONAL COMPANY POLICY FOR DEMO PURPOSES. Halide Labs is a fictional company. This memo is not tax advice.

## 1. Purpose

Whether a vendor should charge tax often depends on certificates and registrations: Halide Labs' own exemption or resale certificates given to vendors, and vendors' tax registration numbers. This procedure keeps those records complete and current so the tax engine's determinations are right.

## 2. Certificates Halide Labs gives to vendors (US)

- Halide Labs issues an exemption or resale certificate to a vendor only when Tax confirms the purchase qualifies in that state.
- If a vendor stops charging sales tax because of a certificate, but the purchase is **not** covered by it, the purchase is taxable to Halide Labs and use tax is accrued under HL-TAX-POL-001.
- Certificates are reviewed annually and when a vendor's product mix changes.

## 3. Registrations Halide Labs holds

Halide Labs' registrations are held in the registrations table (owner_kind = `entity`): US sales and use tax permits for CA, NY, TX and WA; Irish VAT (domestic and Union OSS); UK VAT (non-established); Japan qualified invoice issuer; Singapore GST; Australia GST (simplified). Tax keeps this table current; a change takes effect only from its `effective_from` date.

## 4. Vendor registrations

- For EU reverse charge (HL-TAX-POL-003), the supplier's status as a business established outside Ireland must be supported, and where a VAT number is relied on it is validated before the reverse charge is applied. A registration with `validation_status` other than `valid` is escalated to Tax before the invoice is processed.
- For Japan, input consumption tax credit depends on whether the supplier is a registered qualified invoice issuer (rules `JP-P-QUALIFIED` and `JP-P-NON-QUALIFIED`); the supplier's registration number must appear on the invoice.
- For Singapore, GST charged by a GST-registered supplier (rule `SG-P-DOMESTIC`) is claimable as input tax when the invoice meets local requirements.

## 5. Data handling

Registration and certificate numbers are business identifiers. Access is limited to tax and AP roles; other roles see masked values.
