# Sending mail: server contract, DKIM, bulk-sender requirements

How `isonim-email` hands a message to the world, and what the sending
side must honour. Normative companion to the MIME layer and catalogue
§15 (`R-SND-*`).

## The one-click server contract (R-SND-03)

The library emits `List-Unsubscribe` + `List-Unsubscribe-Post:
List-Unsubscribe=One-Click` (RFC 8058); the URI's server side is the
_sender's_ job. That endpoint MUST:

- accept a POST carrying **no cookies and no auth** — mailbox
  providers send it bare (RFC 8058 §3.1–§3.2);
- **never answer with a redirect** — the provider does not follow
  one, so a 301/302/307/308 silently drops the unsubscribe;
- read the body `List-Unsubscribe=One-Click` as
  `application/x-www-form-urlencoded` **or** `multipart/form-data`;
- answer 2xx once the recipient is unsubscribed.

The library ships the reusable half of that endpoint
(`isonim_email/mime/one_click`): `checkOneClickRequest` takes the
request's method, headers and body and says whether it is a one-click
POST (POST, no `Cookie`, no `Authorization`, the single field
`List-Unsubscribe=One-Click` in either body shape), and
`oneClickResponse` turns the verdict into the answer — 200, or 400
naming the failed requirement, never a 3xx and never a `Location`.
Unsubscribe the recipient the URI identifies before sending the 200.

The round-trip suite runs exactly that in a real HTTP server
(`tests/t6_roundtrip.nim`, "unsubscribe post fixture pins the server
contract"): it POSTs to the URI taken from a library-built message's
`List-Unsubscribe` header, in both body shapes, and checks that a
POST with a cookie and a GET are refused without a redirect. Point a
new endpoint at the same assertions before trusting it with real
unsubscribes.

## DKIM must cover both headers (R-SND-04)

RFC 8058 §4 requires both unsubscribe headers to be covered by a
DKIM signature (the `h=` tag). Signing is the ESP's job — the
library cannot sign — but it records the obligation where the
transports can see it: `toMessage` sets the message's `dkimHeaders`
metadata to `List-Unsubscribe` + `List-Unsubscribe-Post` whenever
the headers are emitted (and to empty when they are not), and the
Mailgun transport sets no `o:dkim` option that would exclude them.
It posts the complete `toRfc5322` bytes to Mailgun's MIME endpoint
(`messages.mime`), so both headers — like every other header,
attachment and inline image — reach Mailgun exactly as built
(`tests/t6_mailgun.nim` checks the request a capture server receives).
If you send through your own transport, sign those two headers.

## Bulk-sender requirements (R-SND-06)

What the big receivers demand of bulk senders (from Feb 2024, with
stricter enforcement from Nov 2025 unless noted):

- **Gmail and Yahoo**: SPF + DKIM on the sending domain, an aligned
  DMARC policy, one-click unsubscribe (`List-Unsubscribe` +
  `List-Unsubscribe-Post`) on marketing mail, and a spam complaint
  rate below 0.3%.
- **Microsoft** (Outlook.com / Microsoft 365, from 2025-05-05): SPF, DKIM and
  DMARC once a sender passes 5,000 messages/day to Microsoft
  recipients.

The library's half: the one-click headers above (with an opaque
per-recipient token in the URI, `R-SND-02`), so the messages it
builds carry what the receivers require. Authentication and
complaint-rate monitoring stay with the sender. For the domain in the
`From` address (or a dedicated sending subdomain of it), the sender
must configure in DNS:

- **SPF**: a `TXT` record at the envelope (Return-Path) domain whose
  `v=spf1` policy authorises the ESP's or relay's sending hosts,
  usually via the `include:` the ESP documents, ending in `~all` or
  `-all`;
- **DKIM**: the ESP's public key as a `TXT` (or delegated `CNAME`)
  record at `<selector>._domainkey.<domain>`, so the ESP signs with
  a `d=` domain aligned with the `From` domain and an `h=` tag
  covering both unsubscribe headers;
- **DMARC**: a `TXT` record at `_dmarc.<domain>` (`v=DMARC1; p=none`
  at first, tightened to `quarantine` or `reject` once reports show
  aligned SPF or DKIM passes), with an `rua=` address for the
  aggregate authentication reports;
- the ESP's own records where it asks for them (a tracking `CNAME`,
  an `MX` for bounce handling on the envelope domain).

Complaint rates are read from the receivers' own sender dashboards
(for Gmail, Postmaster Tools) and the ESP's feedback-loop reports.

## Gmail markup needs a registered sender (R-SND-07)

The schema.org blocks a template attaches with `addGmailMarkup` (go-to
and one-click actions, bills, parcel deliveries) are shown by Gmail only
for mail authenticated with DKIM or SPF and, beyond messages sent to
oneself, from a sender registered with Google. The authentication above
is the first half; [`gmail-markup.md`](./gmail-markup.md) covers the
markup, its checks and the registration.
