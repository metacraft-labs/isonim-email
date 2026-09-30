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

The round-trip suite keeps a reference fixture of this contract: an
in-test server that records the POST and answers a fixed 200 without
a `Location` header (`tests/t6_roundtrip.nim`, "unsubscribe post
fixture pins the server contract"). Point a new endpoint at the same
assertions — POST both body shapes, check the response has no
`Location` — before trusting it with real unsubscribes.

## DKIM must cover both headers (R-SND-04)

RFC 8058 §4 requires both unsubscribe headers to be covered by a
DKIM signature (the `h=` tag). Signing is the ESP's job — the
library cannot sign — but it records the obligation where the
transports can see it: `toMessage` sets the message's `dkimHeaders`
metadata to `List-Unsubscribe` + `List-Unsubscribe-Post` whenever
the headers are emitted (and to empty when they are not), and the
Mailgun transport sets no `o:dkim` option that would exclude them.
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
builds carry what the receivers require. Authentication (SPF, DKIM,
DMARC records) and complaint-rate monitoring stay with the sender's
infrastructure — see the capture host's sending subdomain
(`infra/terraform/cloudflare`, `infra/terraform/mailgun`) for how
this project provisions them.
