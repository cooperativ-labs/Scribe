# Downloaded Scribe reported as damaged

The report attached to Overlord objective `coo:1096.v927` shows macOS saying
“Scribe is damaged and can’t be opened” after a Chrome download. The public
`https://scribe.ovld.ai/download` endpoint resolved to
`Scribe-0.2609271931.0-macos.zip` on 28 September 2026. A fresh download was
byte-for-byte identical to the local release archive (SHA-256
`f6b65b7fe8353e2f8524a426220370bfe4ddc2728723af649f0603f2c3e72368`).

The ZIP was intact, and `ditto -x -k` produced an app with a valid Developer ID
signature and stapled notarization ticket. Gatekeeper accepted that extraction.
This rules out a missing developer dependency as the cause of the launch warning
on the tested Mac. The release is arm64-only and requires macOS 15 or later;
affected users' machine details were not available for verification.

The published ZIP contained 145 AppleDouble `._` metadata entries. Ordinary
`unzip` wrote these as files inside `Scribe.app`, unlike `ditto`, which merged
the metadata. `codesign --verify --deep --strict` then reported added files, and
Gatekeeper rejected the quarantined app with “a sealed resource is missing or
invalid.” This reproduces a packaging route to the reported warning. The
affected users' extraction software was not identified, so their exact route
remains unconfirmed.

`Scripts/package-app.sh` now creates its final ZIP with `ditto --norsrc`, then
extracts that ZIP with `unzip` and verifies its code signature, stapled ticket,
and Gatekeeper acceptance. A trial ZIP from the existing notarized app had no
AppleDouble entries. Its ordinary `unzip` extraction passed all three checks,
including Gatekeeper assessment with a quarantine attribute. A newly published
release is needed to replace the existing downloadable ZIP.

The follow-up distribution change adds a signed, separately notarized DMG to
each GitHub release and makes the website prefer it. The metadata-free ZIP
remains available to the in-app updater and as a fallback for older releases.
