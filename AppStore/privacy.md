# Pulse privacy

Last updated: 31 October 2026

Pulse is made by BuiltBy2 Ltd. It runs on your Mac and has no Pulse account, advertising, tracking SDK or Pulse-hosted analytics service. BuiltBy2 does not receive your database credentials or project data through Pulse.

## On your Mac

Connection settings, cached results, selected KPIs, icons and alert history are stored locally. Credentials entered in the credential field are saved in macOS Keychain. Local widgets receive display summaries through Pulse’s private App Group; they do not receive database credentials.

## Connections you choose

Pulse sends read requests and any saved authentication directly to the API or database provider you connect. Those providers process requests under their own terms and privacy policies. Source links open in your default browser. Only connect sources you are authorised to access; a read-only source credential is recommended.

## Optional private iCloud sync

When you enable iCloud, Pulse sends a small headline summary to your private CloudKit database in your Apple account. It contains project names and symbols, selected metric labels and values, time ranges, and freshness and status information.

Pulse’s iCloud summary does not contain connection addresses, queries, source credentials, custom icon images, individual business or person rows, or alert history. BuiltBy2 cannot read your private CloudKit data. Apple provides iCloud under its own privacy policy and service terms.

You can turn sync off in Settings → iCloud. **Remove iCloud copy** clears the synced numbers and pauses uploads. A small empty sync marker remains to prevent an older Mac from automatically restoring them. Local connections remain saved. Resuming collection after removal requires **Use this Mac**.

## Notifications

Optional alerts are created locally using macOS notifications. Pulse does not use a Pulse-hosted push service. Notification content may appear on your screen or in Notification Centre according to your macOS settings.

## Support

If you contact us, we receive the information you choose to send so we can respond. Do not send credentials, connection strings containing passwords, customer records or private database exports. GitHub issues are public; use email for private support.

Contact: [support@builtby2.co.uk](mailto:support@builtby2.co.uk)

[Apple privacy policy](https://www.apple.com/legal/privacy/) · [BuiltBy2 privacy policy](https://builtby2.co.uk/privacy)
