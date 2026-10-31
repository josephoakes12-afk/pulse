#!/bin/bash
set -euo pipefail

# swift-stdlib-tool may copy arm64e slices even when the host app supports only
# arm64 and x86_64. Keep each bundled runtime limited to its executable's slices
# before signing; an unused slice can otherwise fail App Store validation.
PULSE_EXECUTABLE="${1:-}"
PULSE_FRAMEWORKS="${2:-}"
[[ -f "$PULSE_EXECUTABLE" && -d "$PULSE_FRAMEWORKS" ]] || {
    echo "Usage: $0 executable frameworks-directory" >&2; exit 2;
}
PULSE_SUPPORTED_ARCHITECTURES=" $(lipo -archs "$PULSE_EXECUTABLE") "
while IFS= read -r -d '' PULSE_RUNTIME; do
    for PULSE_RUNTIME_ARCHITECTURE in $(lipo -archs "$PULSE_RUNTIME"); do
        if [[ "$PULSE_SUPPORTED_ARCHITECTURES" != *" $PULSE_RUNTIME_ARCHITECTURE "* ]]; then
            PULSE_TRIMMED="$PULSE_RUNTIME.pulse-trimmed"
            lipo "$PULSE_RUNTIME" -remove "$PULSE_RUNTIME_ARCHITECTURE" -output "$PULSE_TRIMMED"
            chmod 755 "$PULSE_TRIMMED"
            mv "$PULSE_TRIMMED" "$PULSE_RUNTIME"
        fi
    done
done < <(find "$PULSE_FRAMEWORKS" -type f -name '*.dylib' -print0)
