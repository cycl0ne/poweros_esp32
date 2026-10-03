#!/bin/sh
# SPDX-License-Identifier: MIT
# The certificates the X.509 tests read, made with openssl: chains that
# are good, and chains each broken one way. Run again to make new ones;
# the tests take "now" as 03.10.2026, inside every validity below but the
# expired leaf's.
set -eu
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
from=20250101000000Z
until=20350101000000Z

key() { # name algorithm-options...
    name=$1; shift
    openssl genpkey "$@" -out "$work/$name.key" 2>/dev/null
}
ca_ext() { printf 'basicConstraints=critical,CA:TRUE%s\nkeyUsage=critical,keyCertSign,cRLSign\n' "$1" > "$work/$2.ext"; }
leaf_ext() { # name san eku
    printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=%s\nsubjectAltName=%s\n' "$3" "$2" > "$work/$1.ext"
}
sign() { # name subject issuer ext not_after digest-options...
    name=$1 subject=$2 issuer=$3 ext=$4 not_after=$5; shift 5
    openssl req -new -key "$work/$name.key" -subj "$subject" -out "$work/$name.csr" 2>/dev/null
    openssl x509 -req -in "$work/$name.csr" -CA "$work/$issuer.pem" -CAkey "$work/$issuer.key" \
        -set_serial "0x$(openssl rand -hex 8)" -not_before $from -not_after "$not_after" \
        -extfile "$work/$ext.ext" "$@" -out "$work/$name.pem" 2>/dev/null
    openssl x509 -in "$work/$name.pem" -outform DER -out "$name.der"
}

ca_ext "" ca
ca_ext ",pathlen:0" ca0
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n' > "$work/notca.ext"

key root_rsa -algorithm RSA -pkeyopt rsa_keygen_bits:2048
key root_p384 -algorithm EC -pkeyopt ec_paramgen_curve:P-384
key root_ed -algorithm ED25519
for name in root_rsa root_p384 root_ed; do
    openssl req -new -key "$work/$name.key" -subj "/CN=PowerOS Test $name" -out "$work/$name.csr" 2>/dev/null
    openssl x509 -req -in "$work/$name.csr" -key "$work/$name.key" -not_before $from -not_after $until \
        -extfile "$work/ca.ext" -out "$work/$name.pem" 2>/dev/null
    openssl x509 -in "$work/$name.pem" -outform DER -out "$name.der"
done

# An intermediate under the RSA root that may have no CA below it.
key inter -algorithm EC -pkeyopt ec_paramgen_curve:P-256
sign inter "/CN=PowerOS Test Intermediate" root_rsa ca0 $until -sha256

leaf_ext leaf "DNS:www.example.test,DNS:*.example.test,IP:10.0.2.2" serverAuth
key leaf -algorithm EC -pkeyopt ec_paramgen_curve:P-256
sign leaf "/CN=www.example.test" inter leaf $until -sha256
key expired -algorithm EC -pkeyopt ec_paramgen_curve:P-256
sign expired "/CN=www.example.test" inter leaf 20260101000000Z -sha256
leaf_ext client "DNS:www.example.test" clientAuth
key client -algorithm EC -pkeyopt ec_paramgen_curve:P-256
sign client "/CN=www.example.test" inter client $until -sha256

# Signed by the RSA root with RSA-PSS, by the P-384 root, by the Ed25519 root.
leaf_ext pss "DNS:pss.example.test" serverAuth
key pss -algorithm RSA -pkeyopt rsa_keygen_bits:2048
sign pss "/CN=pss.example.test" root_rsa pss $until -sha384 -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:48
leaf_ext p384leaf "DNS:p384.example.test" serverAuth
key p384leaf -algorithm ED25519
sign p384leaf "/CN=p384.example.test" root_p384 p384leaf $until -sha384
leaf_ext edleaf "DNS:ed.example.test" serverAuth
key edleaf -algorithm EC -pkeyopt ec_paramgen_curve:P-384
sign edleaf "/CN=ed.example.test" root_ed edleaf $until

# Broken: a leaf's key used as an issuer; a CA under the pathlen:0 one.
key notca -algorithm EC -pkeyopt ec_paramgen_curve:P-256
sign notca "/CN=PowerOS Test Not A CA" root_rsa notca $until -sha256
leaf_ext under "DNS:under.example.test" serverAuth
key under -algorithm EC -pkeyopt ec_paramgen_curve:P-256
sign under "/CN=under.example.test" notca under $until -sha256
key inter2 -algorithm EC -pkeyopt ec_paramgen_curve:P-256
sign inter2 "/CN=PowerOS Test Second Intermediate" inter ca $until -sha256
leaf_ext deep "DNS:deep.example.test" serverAuth
key deep -algorithm EC -pkeyopt ec_paramgen_curve:P-256
sign deep "/CN=deep.example.test" inter2 deep $until -sha256

ls -1 *.der
