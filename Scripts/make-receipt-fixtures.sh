#!/usr/bin/env bash
# Regenerates Tests/PaywallKitTests/Fixtures: synthetic App Store receipts signed by a throwaway certificate chain
# shaped like Apple's (root → intermediate → "receipt signing" leaf carrying the 1.2.840.113635.100.6.11.1 marker).
# The signatures use the layout of real receipts (PKCS#7 SignedData, no signed attributes, RSA PKCS#1 v1.5 over
# the payload) plus the variants the verifier must also accept or refuse. Keys are discarded; only the root
# certificate and the receipts are kept. Needs openssl 3.4+ (for -not_before/-not_after) and python3.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="Tests/PaywallKitTests/Fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/ext.cnf" <<'CNF'
[ req ]
distinguished_name = dn
prompt = no
[ dn ]
CN = placeholder
[ v3_ca ]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
[ v3_int ]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
[ v3_leaf ]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
1.2.840.113635.100.6.11.1 = ASN1:NULL
[ v3_leaf_nomarker ]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
CNF

cert() { # name subject extensions issuer not_before not_after
  local name=$1 subject=$2 ext=$3 issuer=$4 from=$5 to=$6
  openssl genrsa -out "$WORK/$name.key" 2048 2>/dev/null
  if [[ "$issuer" == self ]]; then
    openssl req -x509 -new -key "$WORK/$name.key" -subj "$subject" -config "$WORK/ext.cnf" -extensions "$ext" \
      -not_before "$from" -not_after "$to" -sha256 -out "$WORK/$name.pem" 2>/dev/null
  else
    openssl req -new -key "$WORK/$name.key" -subj "$subject" -config "$WORK/ext.cnf" -out "$WORK/$name.csr" 2>/dev/null
    openssl x509 -req -in "$WORK/$name.csr" -CA "$WORK/$issuer.pem" -CAkey "$WORK/$issuer.key" -CAcreateserial \
      -extfile "$WORK/ext.cnf" -extensions "$ext" -not_before "$from" -not_after "$to" -sha256 -out "$WORK/$name.pem" 2>/dev/null
  fi
}

cert root "/CN=ZTron Test Root CA/O=ztron-paywall-kit fixtures" v3_ca self 20100101000000Z 20400101000000Z
cert int "/CN=ZTron Test Intermediate CA/O=ztron-paywall-kit fixtures" v3_int root 20100101000000Z 20400101000000Z
cert leaf "/CN=ZTron Test Receipt Signing/O=ztron-paywall-kit fixtures" v3_leaf int 20240101000000Z 20340101000000Z
cert leaf-expired "/CN=ZTron Test Receipt Signing 2015/O=ztron-paywall-kit fixtures" v3_leaf int 20150101000000Z 20160101000000Z
cert leaf-nomarker "/CN=ZTron Test Other Signing/O=ztron-paywall-kit fixtures" v3_leaf_nomarker int 20240101000000Z 20340101000000Z

# The receipt payload: SET OF SEQUENCE { type INTEGER, version INTEGER, value OCTET STRING }, Apple's field numbers.
payload() { # out bundle creation_date_or_empty
  python3 -I - "$1" "$2" "$3" <<'PY'
import sys
out, bundle, created = sys.argv[1:4]
def tlv(tag, body):
    n = len(body)
    if n < 0x80: length = bytes([n])
    elif n < 0x100: length = bytes([0x81, n])
    else: length = bytes([0x82, n >> 8, n & 0xFF])
    return bytes([tag]) + length + body
def attr(kind, value): return tlv(0x30, tlv(0x02, bytes([kind])) + tlv(0x02, b"\x01") + tlv(0x04, value))
utf8 = lambda s: tlv(0x0C, s.encode()); ia5 = lambda s: tlv(0x16, s.encode())
attrs = [attr(0, utf8("Production")), attr(2, utf8(bundle)), attr(18, ia5("2024-03-01T10:00:00Z")), attr(19, utf8("116"))]
if created: attrs.append(attr(12, ia5(created)))
open(out, "wb").write(tlv(0x31, b"".join(attrs)))
PY
}

sign() { # out leaf payload extra-openssl-args...
  local out=$1 leaf=$2 payload=$3; shift 3
  openssl cms -sign -in "$payload" -signer "$WORK/$leaf.pem" -inkey "$WORK/$leaf.key" -certfile "$WORK/int.pem" \
    -binary -nodetach -outform DER -out "$OUT/$out" "$@" 2>/dev/null
}

mkdir -p "$OUT"
payload "$WORK/payload.der" com.ztron.app 2026-01-15T12:00:00Z
payload "$WORK/payload-2015.der" com.ztron.app 2015-06-01T12:00:00Z
payload "$WORK/payload-undated.der" com.ztron.app ""
payload "$WORK/payload-other.der" com.other.app 2026-01-15T12:00:00Z

sign receipt-sha256.der leaf "$WORK/payload.der" -noattr -md sha256          # Apple's layout today
sign receipt-sha1.der leaf "$WORK/payload.der" -noattr -md sha1              # receipts signed before 2023
sign receipt-attrs.der leaf "$WORK/payload.der" -md sha256                   # CMS with signed attributes
sign receipt-expired-leaf.der leaf-expired "$WORK/payload-2015.der" -noattr -md sha256
sign receipt-expired-leaf-undated.der leaf-expired "$WORK/payload-undated.der" -noattr -md sha256
sign receipt-nomarker.der leaf-nomarker "$WORK/payload.der" -noattr -md sha256
sign receipt-other-bundle.der leaf "$WORK/payload-other.der" -noattr -md sha256
openssl x509 -in "$WORK/root.pem" -outform DER -out "$OUT/test-root.der"

for f in "$OUT"/receipt-*.der; do
  openssl cms -verify -inform DER -in "$f" -CAfile "$WORK/root.pem" -binary -purpose any -out /dev/null \
    -attime "$(date -j -f %Y%m%d%H%M%S 20250601000000 +%s 2>/dev/null || date -d 2025-06-01 +%s)" >/dev/null 2>&1 \
    && echo "signed ok: $(basename "$f")" || echo "not verifiable at 2025-06-01 (expected for the expired leaf): $(basename "$f")"
done
ls -la "$OUT"
