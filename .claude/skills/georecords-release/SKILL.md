---
name: georecords-release
description: Use when releasing a new GeoRecords version to the App Store, cutting or re-cutting a vX.Y.Z tag, running the "Release to App Store" workflow, or when that workflow fails (cloud signing errors, test host crashes, upload failures).
---

# GeoRecords App Store Release

## Overview

Publishing a GitHub release tagged `vX.Y.Z` builds, tests, signs, and uploads that version to App Store Connect automatically (`.github/workflows/release.yml`). The tag is the source of version truth; App Store submission is the only manual part.

## Version semantics

- `MARKETING_VERSION` = the tag minus `v` (CI overrides the project setting from the tag)
- `CURRENT_PROJECT_VERSION` (build number) = the CI run number — never set manually
- Tag must match `v<digits>.<digits>[.<digits>]` (e.g. `v1.8.1`) or the workflow fails fast
- Keep the pbxproj `MARKETING_VERSION` in sync anyway (4 entries: app + widget × 2 configs) so local archives agree with CI

## Release procedure

0. **Determine the version.** If not provided with the invocation (e.g. `/georecords-release 1.8.1`), ASK the user which version to release before doing anything else — suggest the next patch number derived from the latest tag (`git tag -l 'v*' --sort=-v:refname | head -1`, or `gh release list --limit 1` if tags aren't local), offering minor/major bumps as alternatives.
1. **Preflight:** on `main`, working tree clean and pushed. Verify `grep -c "MARKETING_VERSION = X.Y.Z" GeoRecords.xcodeproj/project.pbxproj` returns 4. To bump (all 4 entries at once), commit, and push:
   ```bash
   sed -i '' 's/MARKETING_VERSION = OLD.VERSION;/MARKETING_VERSION = X.Y.Z;/g' GeoRecords.xcodeproj/project.pbxproj
   git commit -am "bump version to X.Y.Z" && git push
   ```
2. **Publish the release** (this alone triggers build + upload). Notes = user-facing highlights; the App Store "What's New" text is normally the same list:
   ```bash
   gh release create vX.Y.Z --target main --title "GeoRecords X.Y.Z" --notes "..."
   ```
3. **Watch:**
   ```bash
   gh run list --workflow "Release to App Store" --limit 1
   gh run watch <run-id> --exit-status
   gh run view <run-id> --log-failed   # on failure
   ```
4. **App Store Connect** (manual): wait ~5–30 min for processing → TestFlight sanity pass on device (CI builds with stable Xcode, not local betas) → App Store tab → "+" version X.Y.Z → What's New text → select the CI build → prefer phased release → Submit for Review. Export compliance is answered in-build (`ITSAppUsesNonExemptEncryption=NO`), no questionnaire.

**Dry run without uploading:** Actions tab → "Release to App Store" → Run workflow with `upload` unchecked, or `gh workflow run "Release to App Store" -f upload=false`. Exercises tests, signing, and archive only.

**Re-cutting a release** (e.g., secrets fixed): either `gh run rerun <run-id> --failed` (reruns read the CURRENT secret values, and keep the original run number / build number — fine as long as no build with that number already uploaded for this version), or delete and re-publish for a fresh run number — `gh release delete vX.Y.Z --cleanup-tag --yes` then step 2. Nothing uploaded = nothing to clean up in App Store Connect.

## Signing / secrets

Repository secrets: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (base64 of the `.p8`). Cloud-managed signing — no certificates in the repo.

**Key role gotcha (learned Aug 2026):** an **App Manager** key can *use* the team's cloud-managed Apple Distribution certificate but cannot *create* it. If the cert doesn't exist yet, export fails with `Cloud signing permission error` + `No profiles found`. Fix: in App Store Connect → Users and Access → Integrations → Keys, generate a key with the **Admin** role; update the `ASC_KEY_ID` and `ASC_KEY_P8` secrets (`base64 -i AuthKey_ID.p8 | pbcopy`; issuer ID is account-wide and unchanged); rerun the failed job. The cert now exists permanently — the secrets can optionally be swapped back to an App Manager key and the Admin key revoked.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Cloud signing permission error`, `No profiles for ... found` at Upload step | API key role can't mint the cloud distribution cert — see key role gotcha above |
| Test host crashes: `signal trap before establishing connection`, `Unable to find entitlement for KVS store` | Someone added `CODE_SIGNING_ALLOWED=NO` to the **test** step — remove it; simulator tests sign ad-hoc and need their entitlements |
| Workflow fails at "Derive version from tag" | Tag doesn't match `v<digits>.<digits>[.<digits>]` |
| Workflow doesn't trigger | Only *publishing* a release triggers it — pushed tags and drafts don't. Note: pre-releases DO trigger it |
| Simulator not found in tests | The workflow picks a device by UDID via `simctl list --json`; name-based destinations are unreliable |
| Local test destination fails by name | Same fix locally: use `-destination 'id=<UDID>'` |

## Local build/test commands

See memory `georecords-build-and-test`: builds require `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`; tests need a simulator UUID destination. CI intentionally uses the newest **stable** Xcode instead (App Review rejects beta-SDK binaries).
