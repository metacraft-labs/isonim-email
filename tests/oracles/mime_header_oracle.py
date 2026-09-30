"""Independent MIME header oracle for tests/t6_header_fuzz.nim.

Reads a JSON array of base64-encoded RFC 5322 messages (argv[1]) and
writes, for each, what Python's standard `email` package decodes from
it (argv[2], JSON array, same order):

- from_name / to_name: the display names, via the modern parser
  (policy.default, RFC 2047 phrases);
- from_phrase_legacy: `email.header.decode_header` over the raw From
  phrase (the text before the last " <"), joined with `make_header` --
  the legacy RFC 2047 decoder, independent of the address parser;
- subject / subject_legacy: the Subject via policy.default and via
  `decode_header` + `make_header` over the raw (unfolded) value;
- filename: the attachment filename via `get_filename()` (RFC 2231
  and quoted-string aware), or null without an attachment;
- max_header_line: the longest line in the header blocks;
- defects: every defect the parser recorded on the message, its parts
  and the address/Subject headers.

Standard library only; run by the dev shell's python3.
"""

import base64
import email
import email.policy
import json
import sys
from email.header import decode_header, make_header


def legacy(value):
    return str(make_header(decode_header(value)))


def header_lines(raw):
    out = []
    for part in raw.split(b"\r\n\r\n")[:1]:
        out.extend(part.split(b"\r\n"))
    # Part header blocks: every block that follows a boundary line.
    for chunk in raw.split(b"\r\n--")[1:]:
        head = chunk.split(b"\r\n\r\n", 1)[0]
        out.extend(head.split(b"\r\n")[1:])
    return out


def main():
    with open(sys.argv[1], "rb") as f:
        cases = json.load(f)
    results = []
    for blob in cases:
        raw = base64.b64decode(blob)
        msg = email.message_from_bytes(raw, policy=email.policy.default)
        compat = email.message_from_bytes(raw, policy=email.policy.compat32)
        defects = [repr(d) for d in msg.defects]
        for name in ("From", "To", "Subject"):
            h = msg[name]
            if h is not None:
                defects.extend(repr(d) for d in h.defects)
        raw_from = compat["From"].replace("\r\n", "")
        phrase = raw_from[: raw_from.rfind(" <")] if " <" in raw_from else ""
        raw_subject = compat["Subject"]
        filename = None
        for part in msg.walk():
            defects.extend(repr(d) for d in part.defects)
            if part.get_content_disposition() == "attachment":
                filename = part.get_filename()
        results.append({
            "from_name": msg["From"].addresses[0].display_name,
            "to_name": msg["To"].addresses[0].display_name,
            "from_phrase_legacy": legacy(phrase) if phrase else "",
            "subject": str(msg["Subject"]) if msg["Subject"] is not None else "",
            "subject_legacy": legacy(raw_subject) if raw_subject is not None else "",
            "filename": filename,
            "max_header_line": max(len(l) for l in header_lines(raw)),
            "defects": defects,
        })
    with open(sys.argv[2], "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False)


if __name__ == "__main__":
    main()
