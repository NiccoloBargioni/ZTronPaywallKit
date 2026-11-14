#!/bin/bash
# Prints a `.dev.vars` for Workers/PromotionalOfferSigner that signs with the test key pair stored in
# Tests/PaywallKitTests/Fixtures/Paywall.storekit (its top-level `subscriptionOffersKeyPair`). StoreKit Testing's local
# store server verifies promotional offer signatures against that key pair, so a worker started from this file is the
# one the TestHost live lane can buy through. The key is a throwaway test key, not an App Store Connect key.
#
#   Scripts/worker-dev-vars.sh > Workers/PromotionalOfferSigner/.dev.vars
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -I - Tests/PaywallKitTests/Fixtures/Paywall.storekit <<'PY'
import json, sys, textwrap
pair = json.load(open(sys.argv[1]))["subscriptionOffersKeyPair"]
pem = "-----BEGIN PRIVATE KEY-----\n" + "\n".join(textwrap.wrap(pair["privateKey"], 64)) + "\n-----END PRIVATE KEY-----"
print(f'APPLE_IAP_PRIVATE_KEY="{pem}\n"')
print(f'APPLE_IAP_KEY_ID={pair["id"]}')
print("APPLE_IAP_ISSUER_ID=57246542-96fe-1a63-e053-0824d011072a")
print("APPLE_BUNDLE_IDS=com.example.app,com.ztron.paywall.testhost")
PY
