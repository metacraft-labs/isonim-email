// tools/capture/providers/test_pki.ts — a throwaway certificate
// authority for tests that need real TLS on loopback.
//
// The dev shell has no openssl, and node:crypto signs but cannot issue
// certificates, so this writes the few X.509 structures a TLS server
// needs by hand (DER): a self-signed CA and a server certificate it
// signs, for `localhost` and 127.0.0.1, both on fresh P-256 keys. A test
// hands the CA to its client (`ca`), so the client verifies the server
// exactly as it verifies a public one, against a root it trusts, and a
// client that skipped verification would fail the tests that use a
// certificate from another authority. Nothing here is ever used outside
// tests: the keys live in memory or in the test's scratch directory.

import { generateKeyPairSync, randomBytes, sign } from "node:crypto";
import type { KeyObject } from "node:crypto";
import { Buffer } from "node:buffer";

function len(n: number): Buffer {
  if (n < 0x80) return Buffer.from([n]);
  const bytes: number[] = [];
  for (let v = n; v > 0; v = Math.floor(v / 256)) bytes.unshift(v & 0xff);
  return Buffer.from([0x80 | bytes.length, ...bytes]);
}

function tlv(tag: number, content: Buffer): Buffer {
  return Buffer.concat([Buffer.from([tag]), len(content.length), content]);
}

const seq = (...items: Buffer[]): Buffer => tlv(0x30, Buffer.concat(items));
const set = (...items: Buffer[]): Buffer => tlv(0x31, Buffer.concat(items));
const octets = (b: Buffer): Buffer => tlv(0x04, b);
const utf8 = (s: string): Buffer => tlv(0x0c, Buffer.from(s, "utf8"));
const explicit = (n: number, b: Buffer): Buffer => tlv(0xa0 + n, b);
const TRUE = Buffer.from([0x01, 0x01, 0xff]);

function int(b: Buffer): Buffer {
  let v = b;
  while (v.length > 1 && v[0] === 0 && (v[1]! & 0x80) === 0) v = v.subarray(1);
  if ((v[0]! & 0x80) !== 0) v = Buffer.concat([Buffer.from([0]), v]);
  return tlv(0x02, v);
}

function oid(dotted: string): Buffer {
  const parts = dotted.split(".").map(Number);
  const out: number[] = [40 * parts[0]! + parts[1]!];
  for (const p of parts.slice(2)) {
    const groups: number[] = [];
    let v = p;
    do {
      groups.unshift(v & 0x7f);
      v = Math.floor(v / 128);
    } while (v > 0);
    for (let i = 0; i < groups.length - 1; i++) groups[i]! |= 0x80;
    out.push(...groups);
  }
  return tlv(0x06, Buffer.from(out));
}

// A BIT STRING holding the named bits of a one-byte flag set (DER: the
// unused trailing bits counted).
function flagBits(byte: number): Buffer {
  let unused = 0;
  while (unused < 7 && ((byte >> unused) & 1) === 0) unused++;
  return tlv(0x03, Buffer.from([unused, byte]));
}

function bitString(b: Buffer): Buffer {
  return tlv(0x03, Buffer.concat([Buffer.from([0]), b]));
}

function utcTime(d: Date): Buffer {
  const p = (n: number): string => String(n).padStart(2, "0");
  const s = `${p(d.getUTCFullYear() % 100)}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}Z`;
  return tlv(0x17, Buffer.from(s, "ascii"));
}

const name = (cn: string): Buffer => seq(set(seq(oid("2.5.4.3"), utf8(cn))));
const ECDSA_SHA256 = seq(oid("1.2.840.10045.4.3.2"));

function extension(id: string, critical: boolean, value: Buffer): Buffer {
  return critical
    ? seq(oid(id), TRUE, octets(value))
    : seq(oid(id), octets(value));
}

function pem(label: string, der: Buffer): string {
  const b64 = der.toString("base64").replace(/.{64}/g, "$&\n");
  return `-----BEGIN ${label}-----\n${b64}${b64.endsWith("\n") ? "" : "\n"}-----END ${label}-----\n`;
}

function certificate(
  subject: string,
  issuer: string,
  subjectKey: KeyObject,
  issuerKey: KeyObject,
  extensions: Buffer[],
): Buffer {
  const now = Date.now();
  const tbs = seq(
    explicit(0, int(Buffer.from([2]))),
    int(randomBytes(12)),
    ECDSA_SHA256,
    name(issuer),
    seq(utcTime(new Date(now - 3600_000)), utcTime(new Date(now + 86400_000))),
    name(subject),
    subjectKey.export({ type: "spki", format: "der" }),
    explicit(3, seq(...extensions)),
  );
  const signature = sign("sha256", tbs, issuerKey);
  return seq(tbs, ECDSA_SHA256, bitString(signature));
}

export interface TestPki {
  // The authority a client trusts (PEM).
  caPem: string;
  // The server's certificate followed by the CA's (PEM), and its key
  // (PKCS#8 PEM): what a TLS server is configured with.
  certChainPem: string;
  keyPem: string;
}

// A fresh CA and a server certificate for localhost and 127.0.0.1.
export function makeTestPki(caName = "isonim-email test CA"): TestPki {
  const ca = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const leaf = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const caCert = certificate(caName, caName, ca.publicKey, ca.privateKey, [
    extension("2.5.29.19", true, seq(TRUE)),
    // keyCertSign | cRLSign
    extension("2.5.29.15", true, flagBits(0x06)),
  ]);
  const san = seq(
    tlv(0x82, Buffer.from("localhost", "ascii")),
    tlv(0x87, Buffer.from([127, 0, 0, 1])),
  );
  const leafCert = certificate(
    "localhost",
    caName,
    leaf.publicKey,
    ca.privateKey,
    [
      extension("2.5.29.19", true, seq()),
      // digitalSignature
      extension("2.5.29.15", true, flagBits(0x80)),
      // serverAuth
      extension("2.5.29.37", false, seq(oid("1.3.6.1.5.5.7.3.1"))),
      extension("2.5.29.17", false, san),
    ],
  );
  return {
    caPem: pem("CERTIFICATE", caCert),
    certChainPem: pem("CERTIFICATE", leafCert) + pem("CERTIFICATE", caCert),
    keyPem: leaf.privateKey.export({ type: "pkcs8", format: "pem" }) as string,
  };
}
