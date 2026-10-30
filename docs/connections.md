# Connections

## Add a project

Click **Add Project**, paste the API URL or database connection details, and enter its credential if needed. Connect to preview the available numbers, choose up to three, then add the project. Custom paths, queries and other settings remain available in Advanced.

Click a project's icon during setup, on its card, or in Connections to choose a symbol or an image. Imported images stay on this Mac as small thumbnails; changing an icon does not reconnect the source.

For an existing project, open its settings and choose **Credentials…** to add or replace the token or password without editing the rest of its setup.

For a reusable setup, import a project file such as [project.pulse.json](../examples/project.pulse.json). It contains only connection settings and metric definitions; enter credentials separately. Importing a file never contacts its endpoint or saves a project automatically.

## Time ranges

The range menu uses cached 24-hour, 7-day, 30-day and lifetime summaries. A project can be younger than its selected window; that does not make the window unavailable. Deleted or unrecorded source history cannot be recovered.

Projects appear when their source supports the selected period. The range menu lists projects without history for that period; all saved projects remain in Settings. A plain summary without range data supports lifetime; adding it selects an available period. Use **ⓘ** to choose KPIs; **About this data** explains coverage.

## Connect a service

The guided setup detects API numbers and readable database tables. Declared relationships add totals, averages, maxima, activity and grouped counts. Verified creation dates, boolean fields and small declared enums add further choices. Otherwise, choose the tables to count. Custom filters and queries retain their meaning. The default refresh interval is five minutes.

Open **ⓘ** to put any available KPI in the headline or drawer. When three headlines are selected, choose another KPI and the number it should replace. **More** holds up to six drawer KPIs; **Breakdowns** chooses grouped lists. These choices also apply to widgets and never change collection or alerts.

### HTTP / JSON

Enter an HTTPS endpoint returning a JSON object. HTTP is permitted for loopback addresses during local development. Each metric maps a label to a dot path such as `metrics.accounts` or `results.0.total`.

For **Bearer token**, paste the token; Pulse adds the prefix. For a custom API key, choose **API key / custom header** and supply its header name and exact value. Advanced setup still accepts the complete header value. Secrets are stored in macOS Keychain. Avoid putting tokens in URLs.

See [summary.json](../examples/summary.json) for a complete response and [the summary schema](../examples/summary.schema.json) for its optional fields:

| Field | Meaning |
| --- | --- |
| `measuredAt` | ISO 8601 time the source measured its numbers |
| `coverage` | Short qualification, such as `Consenting web readers` |
| `events` | Events with stable `id`, short `title`, ISO 8601 `occurredAt`, and optional `url` |
| `details` | Optional extra KPIs, as an object or a list of labelled values |
| `breakdowns` | Optional groups with `title` and `rows` containing `id`, `label` and `value` |
| `ranges` | Optional `24h`, `7d`, `30d`, `lifetime` summaries with the same metric paths, optional path-to-label overrides and coverage |
| `alerts` | Optional integer `counters` and calendar-day `daily` observations for native growth alerts |

Additional numeric fields can become extra KPIs automatically. The catalog accepts up to 24 extra KPIs and four grouped lists; the panel shows up to six chosen extras, two groups and ten rows per group. It does not infer totals from arbitrary record arrays. Database groups use declared foreign keys and available display names; averages include visible parents with zero associated records, and records without a visible parent are counted separately. Missing or ambiguous relationships need explicit source mapping. Currency units and revenue definitions are not guessed.

Keep event IDs stable across responses. Retain enough history at the source for Pulse to catch up after being offline. The first successful collection establishes a baseline rather than notifying about old events.

To try a local endpoint without credentials:

```sh
python3 scripts/example-server.py
```

Connect to `http://127.0.0.1:8765/summary` and map `Accounts` to `metrics.accounts` and `Bookings · 7d` to `metrics.bookings7d`. The endpoint serves fake data only.

### PostgreSQL

Use a dedicated read-only database role. Paste its connection string; Pulse separates an included password before saving the address, and stores it in Keychain. A separate password field is also available. Remote connections require verified TLS. Guided setup lists up to 100 readable tables and views.

A query must return one aggregate row; metric paths are its column names. For example:

```sql
SELECT count(*) AS total FROM reporting.project_accounts
```

Pulse applies a read-only transaction and a statement timeout. These limits complement the database role's permissions; use restricted credentials rather than an administrator account. A database row can also return `measuredAt`, `coverage` and a JSON `events` array using the same summary format as HTTP.

### Supabase

Use an imported setup or Advanced with either a project's Data API endpoint or Supabase's restricted read-only SQL endpoint. Data API plans issue bounded exact-count HEAD requests with at most three concurrent requests. Plain creation-count plans gain lifetime totals automatically. Optional catalogs add scoped counts and ratios; bounded grouped requests fetch parent labels and child counts. Grouped lists above 100 parents are omitted with an explanation in **About this data**. SQL summaries use the read-only query route. Both keep credentials in Keychain, reject redirects and return all supported time ranges in one refresh cycle. No schema or role changes are required by the connector.

## Local by design

Optional private iCloud sync sends project names, SF Symbols, selected headline KPIs and their values for each supported period. Source URLs, queries, credentials, events, images and detailed user/business lists stay local. It uses Apple's CloudKit private database; no Pulse server is required. A receiving Mac reads the summary without creating connections or replaying alerts.

Enable it in **Settings → iCloud**. One Mac provides the summary; **Use this Mac** explicitly changes that collector. An Apple Account change pauses sync until you choose the new account. Turning sync off stops transfers and hides received summaries on that Mac; it does not delete the copy already in iCloud. Unsigned source builds remain local-only unless configured for iCloud signing.

**Remove iCloud copy** clears synced project names and numbers and turns off uploads. Other Macs pause when they next sync. A small empty marker remains to prevent an older collector restoring the removed numbers; **Use this Mac** explicitly resumes uploads. Local connections and credentials stay saved.

Configuration, cached summaries and notification receipts live in Application Support. Credentials live in Keychain. Neither belongs in the source repository. Source connections are read-only; notification delivery records are local.

Collection pauses while the app is closed, your Mac is asleep, or the network is unavailable. Pulse keeps the last successful numbers with their timestamp and catches up when possible. New-event alerts catch up over at most seven days, with a bounded local event history. Catch-up depends on the source retaining its history; expired or never-recorded activity cannot be recovered.

Pulse currently provides desktop notifications. It does not send email.
