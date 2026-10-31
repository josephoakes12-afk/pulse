# Submission decisions

Prepared 31 October 2026. These are review notes, not an Apple approval or a legal classification. Leave the app unsubmitted for Joseph’s final review.

## Identity and distribution

- Proposed name: **Pulse: Project Metrics**; check availability in App Store Connect.
- Mac only; English (UK); primary **Developer Tools**, secondary **Productivity**.
- Free; no purchases, subscriptions, ads or account registration.
- Standard Apple licence for the Store listing; the source repository keeps its MIT licence.
- Manual release. Do not press **Add for Review**, **Submit for Review** or **Release This Version** before Joseph reviews it.
- Support/privacy URLs in metadata are usable only after the corresponding files are public and their anonymous responses have been verified.
- Reviewer contact details must come from the account’s authorised contact, not a guessed phone number.

## Privacy label

Proposed response: **Data Not Collected**, subject to a final Store-binary audit.

Reason: Pulse processes source data on-device; it has no developer analytics, advertising SDK, tracking or hosted backend. Its user-selected API/database requests go directly to the user’s chosen source. Optional CloudKit summaries go to the user’s private Apple database, which BuiltBy2 cannot access. Apple states that data processed only on-device is not collected for the label and that developers are not responsible for declaring data collected by Apple itself.

Before saving that response, confirm the Store binary contains no extra telemetry or remote logging SDK and no developer-operated sample endpoint that retains request data. Standard TLS network metadata is handled by the source provider. Optional support email or public GitHub issues are user-initiated support channels; do not add an in-app diagnostic upload without revisiting the privacy response.

Do not claim that nothing leaves the device: source requests and optional private iCloud sync do leave it. Do not claim end-to-end encryption; the current payload uses an ordinary private CloudKit field.

## Age rating and rights

The expected rating is **4+**, calculated by Apple from the current questionnaire. Answer from the final binary, rather than forcing a rating. Pulse has no messaging, social feed, advertisements, user-to-user content publishing, web browser, game, gambling or sensitive-content catalogue. External source links open the default browser. It displays the metrics and source records that the user is authorised to access. Confirm any applicable updated questionnaire wording in App Store Connect, including user-generated content and unrestricted web access, before saving.

App content rights: the app is designed for a user to access their own authorised sources. It does not provide a third-party catalogue. Marketing captures use fictional names and data. Do not imply an endorsement from PostgreSQL, Supabase or Apple.

Accessibility claims should reflect tested features only. Do not select a nutrition label merely because a native control is present.

## Encryption export review

Pulse uses HTTPS through URLSession, Apple CloudKit/Keychain security and standard PostgreSQL TLS through PostgresNIO + swift-nio-ssl. The last dependency embeds BoringSSL, so the app is **not limited to encryption built into Apple’s operating system**. There is no proprietary cryptographic algorithm in Pulse’s application code.

For Apple’s questionnaire, the factual encryption inventory is: encryption is used; standard cryptography is used in addition to Apple OS services; Pulse’s main purpose is displaying project metrics rather than cryptography, VPN, secure communications or security tooling.

Joseph must confirm the exemption/classification and territory decisions before submission, including any France-specific documentation or US reporting obligation. Do not automatically set `ITSAppUsesNonExemptEncryption = NO` simply because part of the app uses HTTPS. Once the determination is established, record it and configure the Info.plist key or Apple-provided compliance code accordingly. A missing compliance answer can hold an uploaded build without submitting the app.

## Final review gate

- [ ] Store app sandbox, outgoing requests, import/icon picker, Keychain, local persistence, widgets, optional alerts and iCloud tested.
- [ ] All displayed sample data labelled; no user credentials or production records in screenshots or reviewer resources.
- [ ] Five ordered 2880×1800 banner tiles and continuous master reviewed.
- [ ] Listing copy, name, categories, price, copyright, support and privacy URLs reviewed.
- [ ] Privacy, rights, age-rating, accessibility and encryption responses confirmed.
- [ ] Exact build/version selected and processed successfully in App Store Connect.
- [ ] Manual release selected; no review submission or public release performed.

Sources: [Apple privacy details](https://developer.apple.com/app-store/app-privacy-details/), [App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information), [Age rating](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating), [Export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance), [Encryption declarations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations).
