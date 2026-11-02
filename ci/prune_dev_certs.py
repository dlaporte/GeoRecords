#!/usr/bin/env python3
"""Revoke the "Created via API" Apple Development certificates earlier CI runs minted.

Every ephemeral runner that archives with automatic signing creates its own Apple
Development certificate (xcodebuild names them "Created via API"); the private key
dies with the runner, so the certificates are dead weight, and Apple caps how many
a team may hold ("Choose a certificate to revoke", 2026-11-02). This revokes the
stale ones so the next archive can mint its own. It never touches distribution
certificates or any certificate with another display name (a developer's Mac).

Environment: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (the .p8). Needs pyjwt and
cryptography. Pass --dry-run to list without revoking.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

import jwt

API = "https://api.appstoreconnect.apple.com/v1"
MINTED_NAME = "Created via API"
DEVELOPMENT_TYPES = {"DEVELOPMENT", "IOS_DEVELOPMENT", "MAC_APP_DEVELOPMENT"}
KEEP_IF_YOUNGER_THAN = timedelta(hours=12)  # a run in flight owns its certificate
CERT_LIFETIME = timedelta(days=365)


def token():
    with open(os.environ["ASC_KEY_PATH"]) as key_file:
        private_key = key_file.read()
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
        private_key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"]},
    )


def request(method, url, bearer):
    req = urllib.request.Request(url, method=method, headers={"Authorization": f"Bearer {bearer}"})
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            body = response.read()
            return response.status, (json.loads(body) if body else {})
    except urllib.error.HTTPError as error:
        return error.code, (json.loads(error.read() or b"{}") if error.headers.get("Content-Type", "").startswith("application/json") else {})


def main(dry_run):
    bearer = token()
    certificates = []
    url = f"{API}/certificates?limit=200"
    while url:
        status, payload = request("GET", url, bearer)
        if status != 200:
            print(f"::error::Listing certificates failed with HTTP {status}: {json.dumps(payload)[:300]}")
            return 1
        certificates.extend(payload.get("data", []))
        url = payload.get("links", {}).get("next")

    now = datetime.now(timezone.utc)
    stale, kept = [], []
    for certificate in certificates:
        attributes = certificate.get("attributes", {})
        kind = attributes.get("certificateType")
        name = attributes.get("displayName") or attributes.get("name") or ""
        if kind not in DEVELOPMENT_TYPES or name != MINTED_NAME:
            continue
        expires = datetime.fromisoformat(attributes["expirationDate"].replace("Z", "+00:00"))
        minted = expires - CERT_LIFETIME
        (kept if now - minted < KEEP_IF_YOUNGER_THAN else stale).append((certificate["id"], attributes.get("serialNumber"), minted.date()))

    print(f"{len(certificates)} certificates on the team; {len(stale)} stale runner-minted development certificates"
          + (f", {len(kept)} recent ones kept" if kept else ""))
    revoked = 0
    for identifier, serial, minted in stale:
        if dry_run:
            print(f"  would revoke {serial} (minted {minted})")
            continue
        status, payload = request("DELETE", f"{API}/certificates/{identifier}", bearer)
        if status == 204:
            revoked += 1
            print(f"  revoked {serial} (minted {minted})")
        else:
            print(f"::error::Revoking {serial} failed with HTTP {status}: {json.dumps(payload)[:300]}. "
                  "The App Store Connect API key needs a role that may revoke certificates (Admin).")
            return 1
    if not dry_run:
        print(f"revoked {revoked} certificate(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main("--dry-run" in sys.argv[1:]))
