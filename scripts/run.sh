#!/bin/bash
set -euo pipefail
PULSE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$PULSE_ROOT/scripts/build-app.sh" "${1:-release}"
open "$PULSE_ROOT/build/Pulse.app"
