# Pulse support

Pulse keeps project numbers in your Mac menu bar and desktop widgets.

## Connect a project

Open Pulse, click **+**, choose a source and add its address and credential. Use a read-only database account. Pulse can discover useful KPIs from supported PostgreSQL structures or use summary data from an API.

## Numbers or history are missing

Keep Pulse running while your Mac is awake. Open the project in Settings and click **Refresh**. Check its address, credential and source permissions. Ranges are available when the source can supply that history; Pulse cannot reconstruct deleted source data.

## Widgets

Right-click the desktop → **Edit Widgets → Pulse**. Add **Project** or **Overview**, then right-click the widget to choose its project and range. macOS controls widget refresh timing.

## iCloud

Use the same Apple account on your Macs. Enable **Settings → iCloud → Private iCloud sync**. Keep the Mac with the source connections running to collect fresh numbers. Only headline summaries sync; credentials remain on the collecting Mac. iPhone and iPad companion apps are not included.

## Contact

Email [support@builtby2.co.uk](mailto:support@builtby2.co.uk) or [report an issue on GitHub](https://github.com/josephoakes12-afk/pulse/issues).

Include your macOS version, Pulse version, source type and the error shown. Never include passwords, API keys, private connection strings or customer records. GitHub issues are public.

[Privacy](privacy.md) · [Connection guide](../docs/connections.md)
