#!/usr/bin/env bash
# Run the cocotb top-level regression against every seeded mutant, at N=4 and
# N=8, and report which ones the tests kill. A mutant survives only if BOTH
# configurations pass. Usage: scripts/run_mutants.sh [SIM [ID...]]
#   SIM defaults to icarus; with IDs, only those mutants run.
set -u
cd "$(dirname "$0")/.."
SIM=${1:-icarus}
shift || true
ONLY=" $* "
WORK=$(mktemp -d)
killed=0
total=0

while IFS=$'\t' read -r id desc; do
    [ "$ONLY" != "  " ] && [[ "$ONLY" != *" $id "* ]] && continue
    total=$((total + 1))
    python3 scripts/mutants.py make "$id" "$WORK/$id" || exit 2
    verdict="SURVIVED"
    detail=""
    for n in 4 8; do
        log="$WORK/$id/N$n.log"
        (cd sim && make SIM="$SIM" TB=accel N="$n" RTL_DIR="$WORK/$id/rtl" \
            SIM_BUILD="$WORK/$id/build_N$n" COCOTB_RESULTS_FILE="$WORK/$id/results_N$n.xml" \
            > "$log" 2>&1)
        fails=$(grep -oE 'FAIL=[0-9]+' "$log" | tail -1 | cut -d= -f2)
        if [ -z "$fails" ]; then
            verdict="KILLED"; detail="$detail N=$n:build/run-error"
        elif [ "$fails" -gt 0 ]; then
            verdict="KILLED"; detail="$detail N=$n:$fails-failing-tests"
        fi
    done
    [ "$verdict" = "KILLED" ] && killed=$((killed + 1))
    printf '%-4s %-9s %-60s%s\n' "$id" "$verdict" "$desc" "$detail"
done < <(python3 scripts/mutants.py list)

echo "mutation score: $killed / $total killed"
rm -rf "$WORK"
