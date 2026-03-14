#!/usr/bin/env bash
set -euo pipefail
cd /mnt/bench/KATANA
out=profiling_results/e2e_instruction_perf_run/compute-canonical/callgrind_pass
VALGRIND_LOG="$out/valgrind.log"
CALL_OUT="$out/callgrind.out.%p"
KATANA_WORKERS=1 PORT=18081 COMPUTE_PORT=18081 \
valgrind --tool=callgrind --instr-atstart=no --dump-instr=yes --collect-jumps=yes --fair-sched=try \
  --callgrind-out-file="$CALL_OUT" --log-file="$VALGRIND_LOG" \
  build/perf-e2e/examples/codegen/compute_api/compute_api \
  >"$out/server.stdout.log" 2>"$out/server.stderr.log" &
srv=$!
for i in $(seq 1 240); do
  python3 - <<PY && break || true
import socket
s=socket.socket(); s.settimeout(0.2)
try:
    s.connect(("127.0.0.1", 18081))
except OSError:
    raise SystemExit(1)
finally:
    s.close()
PY
  sleep 0.25
done
callgrind_control -i on $srv >/dev/null
KATANA_PIPELINE_DEPTH=10 wrk -t1 -c8 -d1s --latency -s test/load/scripts/compute_sum_pipeline.lua http://127.0.0.1:18081/ > "$out/wrk_output.txt"
callgrind_control --dump=after_wrk $srv >/dev/null || true
callgrind_control -i off $srv >/dev/null || true
kill -TERM $srv 2>/dev/null || true
for i in $(seq 1 10); do
  kill -0 $srv 2>/dev/null || break
  sleep 0.5
done
kill -KILL $srv 2>/dev/null || true
cg=$(find "$out" -maxdepth 1 -name "callgrind.out.*" | sort | tail -n1)
callgrind_annotate --inclusive=yes --tree=both --auto=yes "$cg" > "$out/callgrind_annotate.txt"
echo done > "$out/status.txt"
