# Development

Requires macOS 14 or later and Xcode with Swift 6.2 or later.

```sh
swift test --configuration release
scripts/run.sh
```

`scripts/build-app.sh` builds `build/Pulse.app` without opening it. Local builds are ad hoc signed for development. Release bundles remove debugging symbols and remap build paths; `scripts/run.sh debug` keeps symbols for development.

The main areas are:

- `Sources/Pulse`: the native Mac interface.
- `Sources/PulseCore`: connectors, models, Keychain and local persistence.
- `Sources/PulseWidgetData` and `Widgets`: display-only snapshots and native widgets.
- `Tests`: synthetic connector and persistence checks.

Examples contain fake data. Never commit credentials, private connection files or cached project data. Keep source connections read-only and the interface compact.

## Release

Run the release tests and commit the reviewed source, then package one universal app for Apple silicon and Intel:

```sh
export PULSE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export PULSE_NOTARY_PROFILE='your-existing-notary-profile'
scripts/package-release.sh 0.1.0
```

This creates a signed, notarized disk image, a ZIP containing the stapled app, and `SHA256SUMS` under `build/releases/0.1.0/`. The disk image contains only Pulse and an Applications shortcut. Notarization receipts stay in ignored `.local/releases/`.

The identity must be a **Developer ID Application** certificate. An Apple Development certificate cannot replace it. Configure a notarytool Keychain profile using [Apple’s notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow); do not put credentials in a script or the repository.

Signed Developer ID builds include the WidgetKit extension automatically. Its small Xcode target compiles only the shared display models, not database connectors. The app and sandboxed extension share aggregate numbers through a private `TEAMID.local.pulse.shared` App Group. This Mac-only format requires no portal registration. Credentials and individual records are never exported.

Ad hoc development builds omit live widgets because App Group access needs a real signing team. For an Apple Development build, set `PULSE_DEVELOPMENT_TEAM` explicitly as well as `PULSE_SIGN_IDENTITY`. `scripts/build-widget.sh build/widget-preview release` compiles the unsigned extension and its App Intents metadata for verification.

Widgets currently run on macOS. iPhone/iPad widgets would need a companion app and optional summary synchronization; Mac widgets do not appear on those devices automatically.

Private iCloud sync is optional at build time. The official app uses `uk.co.builtby2.pulse`. For a fork, choose your own globally unique reverse-DNS identifier, register that explicit App ID with CloudKit, associate your own iCloud container, and generate a **Developer ID** provisioning profile for the signing certificate. Deploy [Cloud/Schema.ckdb](../Cloud/Schema.ckdb) to that container's Production environment. The schema is private-only and grants no public-database access. Set these alongside the signing identity when building or packaging:

```sh
export PULSE_BUNDLE_IDENTIFIER='com.example.pulse'
export PULSE_CLOUDKIT_CONTAINER='iCloud.com.example.pulse'
export PULSE_CLOUDKIT_PROFILE='/absolute/path/to/Pulse.provisionprofile'
```

The builder validates the profile's team, selected App ID, certificate, expiry and CloudKit authorization, embeds it, and signs only the required Production CloudKit privileges. The widget identifier follows the selected App ID with `.widgets`; its extension keeps App Group privileges and reads the host's display cache. Profiles and Apple credentials stay outside the repository. Builds without the CloudKit variables remain local-only and need no iCloud setup. `python3 -m unittest discover -s Tests/Packaging` checks signing configuration with synthetic data.

For a local packaging check, `scripts/package-release.sh 0.1.0 --unsigned` produces explicitly labelled previews. They are not the public download.

Before publishing, mount the final disk image, verify its contents, and launch the copied app with a fresh local profile. Test installation on the oldest supported macOS version and both CPU families before claiming those combinations have been tested. Upload only the final DMG, ZIP and checksum file to a tagged GitHub release.

## Mac App Store

The Store build uses the same source with a separate distribution configuration. Its main app is sandboxed, permits outgoing connections and user-selected file reads, and uses Store-managed updates. Developer ID downloads retain their existing behavior.

Use explicit **Mac App Store** profiles for the main app and widget, an **Apple Distribution** or **Mac App Distribution** application certificate, and a **Mac Installer Distribution** installer certificate. The main profile must authorize the selected Production CloudKit container when iCloud is included. The widget needs only its own App ID and the shared App Group; it never connects to databases or CloudKit.

```sh
export PULSE_SIGN_IDENTITY='Apple Distribution: Your Name (TEAMID)'
export PULSE_INSTALLER_SIGN_IDENTITY='3rd Party Mac Developer Installer: Your Name (TEAMID)'
export PULSE_DEVELOPMENT_TEAM='TEAMID'
export PULSE_APP_STORE_PROFILE='/absolute/path/to/PulseStore.provisionprofile'
export PULSE_WIDGET_PROFILE='/absolute/path/to/PulseWidgetsStore.provisionprofile'
export PULSE_CLOUDKIT_CONTAINER='iCloud.com.example.pulse'
export PULSE_BUILD_NUMBER='6'
scripts/package-app-store.sh 0.1.0
```

Set `PULSE_BUNDLE_IDENTIFIER` for your own fork, as above. The App Group defaults to `TEAMID.local.pulse.shared`; `PULSE_APP_GROUP_IDENTIFIER` can select another authorized group. Apple permits team-prefixed macOS App Groups without portal registration. A registered `group.` identifier must be authorized in both profiles. Set optional `PULSE_SIGNING_KEYCHAIN` to a task-specific signing keychain to avoid changing the user's keychain search list.

The script requires committed source and creates a universal `Pulse.xcarchive`, signed upload `.pkg`, checksum and build receipt under `build/app-store/<version>/`. It embeds and validates both profiles, stores debug symbols in the archive, and does not upload, submit, notarize or release anything. Use `PULSE_STORE_DIR` for a new output directory when rebuilding the same version. A Store-signed app is intended for Apple's processing; use an appropriately development-signed sandbox build for local runtime checks and TestFlight for distribution testing.

For sandbox QA without packaging, set `PULSE_DISTRIBUTION_CHANNEL=app-store` and the Store signing variables above before `scripts/build-app.sh release`. Signing profiles, certificates, credentials and App Store receipts remain local. Do not set encryption-compliance declarations merely because the app uses HTTPS: the PostgreSQL connector bundles SwiftNIO SSL/BoringSSL and needs a declaration covering that implementation.

[Apple packaging guidance](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution) · [App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox) · [App Group containers](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)

## Connector tests

The normal suite uses synthetic data and never queries a real project. To try an HTTP source locally:

```sh
python3 scripts/example-server.py
```

Connect to `http://127.0.0.1:8765/summary`. See the [connection guide](connections.md) for its response contract.

The opt-in PostgreSQL test needs a **new disposable local database**. As a local administrator:

```sh
createdb --host=127.0.0.1 pulse_test_analytics
psql --host=127.0.0.1 -v ON_ERROR_STOP=1 -d pulse_test_analytics -f Tests/Fixtures/postgres-analytics.sql
psql --host=127.0.0.1 -d pulse_test_analytics -c '\password pulse_reader'
```

The one-shot fixture creates synthetic data and a SELECT-only login. It fails if its role or objects already exist. In zsh, run the check without storing the password in a URL or shell history:

```sh
read -s 'PULSE_TEST_POSTGRES_PASSWORD?Test database password: '
export PULSE_TEST_POSTGRES_PASSWORD
PULSE_TEST_POSTGRES_URL='postgresql://pulse_reader@127.0.0.1:5432/pulse_test_analytics?sslmode=disable' \
  swift test --configuration release --filter postgresAnalyticsAgainstLocalSyntheticFixture
unset PULSE_TEST_POSTGRES_PASSWORD
```

The test accepts loopback addresses only. Without that environment variable, it does not connect.
