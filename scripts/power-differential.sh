#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
COUNT="${1:-30}"
OUT="${2:-/tmp/wattly-power-differential-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"

if ! [[ "$COUNT" =~ '^[0-9]+$' ]] || (( COUNT < 1 )); then
  print -u2 'usage: scripts/power-differential.sh [sample-count] [output-directory]'
  exit 64
fi

print 'This manual diagnostic needs sudo only for Apple powermetrics.'
print 'Wattly/IOReport remains unprivileged. No password is stored.'
sudo -v

PROBE="$OUT/power-differential-probe"
xcrun swiftc -parse-as-library -o "$PROBE" \
  "$ROOT/Wattly/Models/CardKind.swift" \
  "$ROOT/Wattly/Models/MetricSample.swift" \
  "$ROOT/Wattly/Models/MetricState.swift" \
  "$ROOT/Wattly/Core/MetricProvider.swift" \
  "$ROOT/Wattly/Core/ProcessList.swift" \
  "$ROOT/Wattly/Core/ProcessPower.swift" \
  "$ROOT/Wattly/Core/PowerEnergy.swift" \
  "$ROOT/Wattly/Providers/PowerProvider.swift" \
  "$ROOT/scripts/power-differential.swift" \
  -framework IOKit

sudo -n powermetrics --samplers cpu_power -i 1000 -n "$COUNT" \
  > "$OUT/powermetrics.txt" 2> "$OUT/powermetrics.err" &
PM_PID=$!
"$PROBE" "$COUNT" > "$OUT/ioreport.csv"
wait "$PM_PID"

awk -F, '
  NR > 1 { n++; rollup += $2; cores += $3; clusters += $4; gpu += $5; ane += $6 }
  END {
    if (!n) exit 2
    printf "IOReport samples=%d rollup=%.3fW per-core=%.3fW clusters=%.3fW gpu=%.3fW ane=%.3fW\n", \
      n, rollup/n, cores/n, clusters/n, gpu/n, ane/n
  }
' "$OUT/ioreport.csv" | tee "$OUT/summary.txt"

awk '
  /^CPU Power:/ { cpu += $3; n++ }
  /^GPU Power:/ { gpu += $3 }
  /^ANE Power:/ { ane += $3 }
  /^Combined Power/ { combined += $8 }
  END {
    if (!n) exit 2
    printf "powermetrics samples=%d cpu=%.3fW gpu=%.3fW ane=%.3fW combined=%.3fW\n", \
      n, cpu/n/1000, gpu/n/1000, ane/n/1000, combined/n/1000
  }
' "$OUT/powermetrics.txt" | tee -a "$OUT/summary.txt"

print "Artifacts: $OUT"
