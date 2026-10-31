# App Store review pack

Submitted for App Review on 31 October 2026 at 12:39 UTC. Apple reports **Waiting for Review**. Release remains **Manual**; no public App Store release has been made.

- [Listing copy](en-GB/metadata.json)
- [Review instructions](review-notes.txt)
- [Screenshot plan](capture-plan.md)
- [Privacy policy](privacy.md)
- [Support](support.md)
- [Submission decisions](compliance.md)

Use the same compact Pulse app, with App Store signing, sandboxing and Store-managed updates. Existing GitHub connections do not need to migrate; users can reconnect in the Store version.

The listing name is **Pulse: Project Metrics**, App Store Connect app `6829198481`. The app itself remains Pulse.

Submitted version **0.1.0**, build **7**. Apple validated and processed the universal Store build successfully. Build 7 includes the complete pinned redistribution notices for both bundled BoringSSL versions.

The en-GB listing copy, categories, Apple-calculated **4+** age rating, review notes and authorised reviewer contact are saved. Pricing is free in 174 territories; France is excluded pending its encryption documentation requirements. Release mode is **Manual**. Five continuous banner panels are uploaded in order and processed **Complete**.

Public URLs are published and checked anonymously:

- Support: `https://github.com/josephoakes12-afk/pulse/blob/main/AppStore/support.md`
- Privacy: `https://github.com/josephoakes12-afk/pulse/blob/main/AppStore/privacy.md`
- Marketing: `https://github.com/josephoakes12-afk/pulse`

Joseph approved the banners and authorised submission after CI passed. Submission `333230c1-edc8-4af3-b66d-220123a0f5fe` was accepted by Apple at `2026-10-31T12:39:34.484Z`. Approval is pending; keep release manual.

The **Data Not Collected** privacy label is published. Content rights cover user-authorised API/database content. The encryption questionnaire declares standard algorithms outside Apple’s operating system and no distribution in France; Apple recorded `usesNonExemptEncryption: false` for build 7. See [submission decisions](compliance.md).

Local QA passed 173 Swift tests and 17 packaging checks. [CI run 41199627070](https://github.com/josephoakes12-afk/pulse/actions/runs/41199627070) passed on Apple silicon and Intel for the binary source `b9cccb36ffd9700b8bca1816629715acea964f61`. A sandboxed developer copy also passed authenticated HTTP after restart, PostgreSQL discovery, setup-file import, cache/offline recovery and a read-only private CloudKit probe. This does not establish an actual App Store installation or second-Mac reception.

Media masters, captures, review page and upload receipts stay local under ignored `.local/app-store/`. The five 2880×1800 screenshots are consecutive slices of one 14400×1800 master. The widget image uses the unchanged production widget views in a native preview host with fictional data; it is not a capture of the desktop WidgetKit host.
