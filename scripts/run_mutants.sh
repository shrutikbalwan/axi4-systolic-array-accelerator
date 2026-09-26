#!/usr/bin/env bash
# Run the designated cocotb or formal regression against every seeded mutant.
# Cocotb mutants run at N=4 and N=8; the DMA page-clamp mutants run their
# protocol proof. Usage: scripts/run_mutants.sh [SIM [ID...]]
#   SIM defaults to icarus; with IDs, only those mutants run.
set -u
cd "$(dirname "$0")/.."
SIM=${1:-icarus}
shift || true
ONLY=" $* "
WORK=$(mktemp -d)
killed=0
total=0

while IFS=$'\t' read -r id tb desc; do
    [ "$ONLY" != "  " ] && [[ "$ONLY" != *" $id "* ]] && continue
    total=$((total + 1))
    python3 scripts/mutants.py make "$id" "$WORK/$id" || exit 2
    verdict="SURVIVED"
    detail=""
    if [[ "$tb" == formal_* ]]; then
        mkdir -p "$WORK/$id/formal"
        cp formal/axi_fvip_compat_properties.sv "$WORK/$id/formal/"
        if [ "$tb" = "formal_read_dma" ]; then
            proof="axi4_read_dma"
        else
            proof="axi4_write_dma"
        fi
        cp "formal/$proof.sby" "formal/${proof}_formal.sv" "$WORK/$id/formal/"
        log="$WORK/$id/formal.log"
        if (cd "$WORK/$id/formal" && sby -f "$proof.sby" prove > "$log" 2>&1); then
            detail=" formal-proof-passed"
        elif grep -Eq 'DONE \(FAIL|Status returned by engine: FAIL' "$log"; then
            verdict="KILLED"; detail=" formal-assertion-failed"
        else
            verdict="ERROR"; detail=" formal-build/run-error"
        fi
        [ "$verdict" = "KILLED" ] && killed=$((killed + 1))
        printf '%-4s %-9s %-60s%s\n' "$id" "$verdict" "$desc" "$detail"
        continue
    fi
    for n in 4 8; do
        log="$WORK/$id/N$n.log"
        (cd sim && make SIM="$SIM" TB="$tb" N="$n" RTL_DIR="$WORK/$id/rtl" \
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
[ "$killed" -eq "$total" ]
