# Pulse

A small, local macOS menu-bar app for the few project numbers you want to keep an eye on. Built with SwiftUI and AppKit, with generic HTTP/JSON and read-only PostgreSQL connectors.

Each project gets a compact row with up to three metrics. New source events can produce optional desktop notifications. Demo data is clearly labelled; connecting a service does not invent measurements that it does not already record.

## Run

Requires macOS 14 or later and Xcode with Swift 6.2 or later.

```sh
swift test
scripts/run.sh
```

The build script creates `build/Pulse.app` and signs it locally for development. It does not install a background service, publish a release, or notarize the app for distribution. To build without opening it, run `scripts/build-app.sh`. Use `scripts/run.sh debug` for a faster development build.

## Connect a service

Open Pulse from the menu bar, then open Connections and add a project. Choose the connection type, supply its details, and name up to three metrics. The default refresh interval is five minutes.

### HTTP / JSON

Enter an HTTPS endpoint returning a JSON object. HTTP is permitted for loopback addresses during local development. Each metric maps a label to a dot path such as `metrics.accounts` or `results.0.total`.

If authentication is needed, choose the header name and enter its exact value in the secret field; for bearer authentication that means `Bearer YOUR_TOKEN`. Secrets are stored in macOS Keychain. Avoid putting tokens in URLs.

See [examples/summary.json](examples/summary.json) for a complete response and [the summary schema](examples/summary.schema.json) for its optional fields:

| Field | Meaning |
| --- | --- |
| `measuredAt` | ISO 8601 time the source measured its numbers |
| `coverage` | Short qualification, such as `Consenting web readers` |
| `events` | Events with stable `id`, short `title`, ISO 8601 `occurredAt`, and optional `url` |

Keep event IDs stable across responses. Retain enough history at the source for Pulse to catch up after being offline. The first successful collection establishes a baseline rather than notifying about old events.

To try a local endpoint without credentials:

```sh
python3 scripts/example-server.py
```

Connect to `http://127.0.0.1:8765/summary` and map `Accounts` to `metrics.accounts` and `Bookings · 7d` to `metrics.bookings7d`. The endpoint serves fake data only.

### PostgreSQL

Use a dedicated database role limited to the aggregate data it needs. Enter a connection URL such as `postgresql://pulse_reader@db.example.com:5432/app` and put the password in the separate Keychain secret field. Remote connections require verified TLS.

A query must return one aggregate row; metric paths are its column names. For example:

```sql
SELECT count(*) AS total FROM reporting.project_accounts
```

Pulse applies a read-only transaction and a statement timeout. These limits complement the database role's permissions; use restricted credentials rather than an administrator account. A database row can also return `measuredAt`, `coverage` and a JSON `events` array using the same summary format as HTTP.

## Local by design

Configuration, cached summaries and notification receipts live in Application Support. Credentials live in Keychain. Neither belongs in the source repository. Source connections are read-only; notification delivery records are local.

Collection pauses while the app is closed, your Mac is asleep, or the network is unavailable. Pulse keeps the last successful numbers with their timestamp and catches up when possible. New-event alerts catch up over at most seven days, with a bounded local event history. Catch-up depends on the source retaining its history; expired or never-recorded activity cannot be recovered.

This first version has desktop notifications. Email delivery, additional service adapters and an always-on collector can follow without enlarging the main card.

## Extending

`PulseCore` keeps the connector contract, collection models and persistence separate from the Mac interface. A connector returns a `ProjectSnapshot`: selected metrics, optional events, and measurement times. Add an adapter for a service with a different API or authentication flow; anything without accessible data or an adapter needs integration work first.

The repository contains generic code and fake examples. Private project connection details stay in local settings. Publishing the repository and distributing signed releases are separate steps.

MIT licensed. PostgreSQL support uses [PostgresNIO](https://github.com/vapor/postgres-nio), under its own licence.
