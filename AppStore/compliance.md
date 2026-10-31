# Submission decisions

Submitted 31 October 2026 at `2026-10-31T12:39:34.484Z`. Apple reports **Waiting for Review** for version **0.1.0**, build **7**, submission `333230c1-edc8-4af3-b66d-220123a0f5fe`. These notes record the declarations; they are not Apple approval or a legal classification.

## Identity and distribution

- **Pulse: Project Metrics**, App Store Connect app `6829198481`.
- Mac only; English (UK); primary **Developer Tools**, secondary **Productivity**; Apple-calculated **4+** rating.
- Free in 174 territories. France is excluded at Joseph’s request pending its encryption documentation requirements.
- No purchases, subscriptions, ads or Pulse account registration.
- Standard Apple licence for the Store listing; MIT licence for the source repository.
- **Manual release** retained. No public App Store release has been made.
- Public support/privacy URLs and authorised reviewer contact were verified saved. Private contact values are omitted from receipts.

## Privacy label

Published: **Data Not Collected**. The binary/dependency audit found no developer analytics, advertising or remote diagnostic SDK.

Pulse processes source data on-device. User-selected API/database requests go directly to the chosen source. Optional CloudKit summaries use the user’s private Apple database, which BuiltBy2 cannot access. Apple excludes on-device processing and data collected by Apple itself from the developer’s label.

Source requests and optional private iCloud sync do leave the device. Do not claim that nothing leaves it or that CloudKit payloads are end-to-end encrypted. Revisit the label if developer telemetry or diagnostic uploads are added.

## Content rights and accessibility

Saved: `USES_THIRD_PARTY_CONTENT`. Pulse accesses external API/database content only through the user’s authorised sources. It supplies no third-party catalogue. Marketing captures use labelled fictional data; bundled dependency redistribution notices are included. Do not imply provider endorsement.

External source links open the default browser. Pulse has no messaging, social feed, advertisements, user-to-user publishing, embedded browser, game, gambling or sensitive-content catalogue. Accessibility claims must reflect tested features; no unverified label is asserted.

## Encryption export answers

Pulse uses URLSession HTTPS, CloudKit/Keychain and PostgreSQL TLS through PostgresNIO + swift-nio-ssl, which embeds BoringSSL. It is **not limited to encryption built into Apple’s operating system**. Its main purpose is displaying project metrics, and its application code adds no proprietary cryptographic algorithm.

The submitted questionnaire selected **standard encryption algorithms instead of, or in addition to, Apple’s operating system** and **No** to distribution in France. After those answers, Apple recorded `usesNonExemptEncryption: false` for build 7. This was not inferred from HTTPS alone. No French declaration has been filed; France must remain excluded until the applicable requirements are fulfilled.

## Verification and limits

Joseph approved the banner captures and authorised submission once CI passed. Apple validated and processed build 7 successfully. Five ordered 2880×1800 banner panels are complete, with fictional sample data and no production credentials.

Local QA passed 173 Swift tests and 17 packaging checks. [CI run 41199627070](https://github.com/josephoakes12-afk/pulse/actions/runs/41199627070) passed on Apple silicon and Intel for binary source `b9cccb36ffd9700b8bca1816629715acea964f61`. Sandboxed local acceptance covered authenticated HTTP after restart, PostgreSQL discovery, setup-file import, cache/offline recovery and a read-only private CloudKit probe. An actual App Store installation and reception on a second Mac have not been established.

Sources: [Apple privacy details](https://developer.apple.com/app-store/app-privacy-details/), [App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information), [Age rating](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating), [Export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance), [Encryption documentation](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/).
