# Windows release policy

The owner selected unsigned public releases on 2026-11-21. Paid certificate
enrollment is cancelled; no provider account or certificate is required.

Build explicitly with:
    npm run package:windows -- --unsigned-release

This emits the normal dist/windows artifact with WINDOWS-SIGNATURE.json:
status=UNSIGNED_RELEASE, releaseAllowed=true, publisherSignatureVerified=false.
Its per-file SHA-256 inventory checks package integrity, NOT publisher trust.
CI verifies that inventory and runs native fixture checks before publication.
The public download page and bundled instructions disclose Smart App Control
limitations. No code changes Windows security settings or installs a root.

--unsigned-test remains local-only, uses dist/windows-test and a filename
suffix plus UNSIGNED-TEST-ONLY.txt. It must never be published.

Calling the packager without an unsigned flag retains the optional future
trusted-signing path: an enrolled certificate must be pinned explicitly and
pass the independent Windows signature verifier. No signing enrollment is
planned for this release.

Publication gates: edition scope, blank new-user setup, existing account and
persistent session compatibility, encrypted TG settings and daily deduplication,
native Windows launch/relaunch, macOS universal package checks, privacy scan,
final archive hashes and working release links. Payment/configuration operations
are never replayed. Test sends and production configuration changes are excluded.
