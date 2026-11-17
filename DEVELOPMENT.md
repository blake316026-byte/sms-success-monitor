# Public Workbench Development

This branch contains the public, reduced edition. The private/full working copy and installed application are maintained separately and must not be overwritten by a public release.

## Boundaries

- No fleet overview, country financial totals, monitor widget, alarm notification or monitor-mode controls.
- No periodic SMS or financial collection. The existing session, login and page-lifecycle helpers remain for workbench access.
- macOS and Windows support pending withdrawals and withdrawal reviewer queries, including navigation, pagination, filtered server totals, daily cache and configurable refresh. Android retains its existing workbench capabilities and does not yet implement these query windows.
- Windows builds its injected query and navigation scripts directly from the macOS script constants. Its own host service manages page reuse, cancellation, one-day encrypted caching and refresh scheduling.
- Application identifiers and data directories are separate from the full edition. Users configure their own platform URLs and sign in; no private data is imported automatically.
- Android uses a bound page service only. No overlay permission, boot receiver or monitor foreground service.
- Historical tags/releases are not rewritten or removed. Only this version and the current download links are reduced.

## Build And Verify

- Pending NPG audit orders use `/api/withdraw_audit_record/page` with `status=PENDING`, country and the site's permission-based `invitedCountType`; their visible/search ID is `withdrawOrderId`, not the audit record ID. Navigation targets `/withdraw-audit-record-list`. Payout exceptions retain `/api/withdraw_record/page`, `status=ERROR` and `/withdraw-record-list`.
- TC pending-order navigation selects `pending`, `pending_review` or `paid` from the canonical order status, then clears old form filters and searches the exact ID. Confirmation requires the matching pending-query endpoint. Reviewer searches continue to use All.
- Regression fixtures cover sequential audit order IDs, TC status-tab switching and return, rejection of an All-tab request, clearing stale reviewer filters, per-group NPG permissions and warm-page reuse. Electron host tests also verify the audit versus exception fallback URL.

- macOS: `zsh scripts/test.sh`, then `zsh scripts/package-macos.sh`.
- Windows: `zsh scripts/package-windows.sh`; packaged runtime checks run on the Windows CI runner.
- Android: `zsh scripts/package-android.sh` with JDK 17 and an authorized Android SDK (API 35).
- `node scripts/check-public-edition.mjs` checks removed windows, IPC, polling and independent storage.
- Windows tests cover query state and scheduling plus packaged Electron windows and NPG/TC controlled-form fixtures. These are isolated fixtures, not a claim of live account acceptance on every platform.
- Release CI builds and checks Windows/Android from the candidate source. macOS is built locally and its packaged runtime and signature are verified before publication.
- Never reuse an old full-edition seed or attach an older Windows/Android package.
- Do not include local credentials, cookies, module overrides, query caches, screenshots, operational logs or internal validation notes in Git.
- After all checks pass, tag the tested commit, upload the changed platform packages and SHA256SUMS, then verify the published asset hashes and latest Release. Pin unchanged platform downloads to their last release.

## v0.3.86 Scope

- Only pending-order creation time, elapsed time and visual overdue alerts change. No new payment, SMS channel, retention or AI configuration modules are included.
- The minimum-wait filter is inclusive in minutes, combines with platform/text filters, resets pagination, and is ignored on platform status/reviewer views. Blank or zero disables it; unknown/future times do not match a positive minimum. Filtering makes no backend request.
- NPG creation time comes from `created`; TC uses `requestTime`. Numeric epoch milliseconds and explicit timestamp offsets are preserved. Naive TC timestamps use the backend environment timezone (S1/S3 UTC-4, otherwise UTC+8); ambiguous NPG strings remain unknown.
- Display times in Asia/Shanghai. Alert only when the elapsed time is strictly greater than 20 minutes and the order is confirmed pending. Invalid/future/missing timestamps and unconfirmed previous results do not alert. Failed queries remove previous rows.
- Native AppKit, WebKit, shared query fixtures, Windows host state tests and packaged Electron rendering cover the new fields, threshold, cancellation/stale results and layout. No production order is processed by these checks.
- macOS and Windows versions become 0.3.86; application identities and data locations are unchanged. Android stays at 0.3.85 and its download link is pinned.
