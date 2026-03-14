#!/usr/bin/env bash
set -euo pipefail
cd /mnt/bench/KATANA
out=profiling_results/e2e_instruction_perf_run/hello-canonical/strace_pass3
strace -f -c -o "$out/strace_summary.txt" env KATANA_WORKERS=1 HELLO_PORT=18080 build/perf-e2e/hello_world_server > "$out/server.stdout.log" 2> "$out/server.stderr.log" &
tracer=$!
for i in $(seq 1 120); do
  python3 - <<PY && break || true
import socket
s=socket.socket(); s.settimeout(0.2)
try:
    s.connect(("127.0.0.1",18080))
except OSError:
    raise SystemExit(1)
finally:
    s.close()
PY
  sleep 0.25
done
KATANA_PIPELINE_DEPTH=10 wrk -t1 -c32 -d2s --latency -s test/load/scripts/hello_pipeline.lua http://127.0.0.1:18080/ > "$out/wrk_output.txt"
kill -INT $tracer 2>/dev/null || true
wait $tracer || true
echo done > "$out/status.txt"
