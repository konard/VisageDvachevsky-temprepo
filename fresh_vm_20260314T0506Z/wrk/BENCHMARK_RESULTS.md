# KATANA Benchmark Results

> Last updated: 2026-03-14 05:06:10

## Summary

- Stability verdict: stable enough for trend tracking
- Noisy metrics (CV > 20.0%): 0
- Severely noisy metrics (CV > 40.0%): 0
- E2E network stages included: yes

> **Note**: Results shown use median-of-N aggregation across 5 run(s) per stage. Concurrent benchmarks are highly sensitive to system load and thread scheduling.

---

## Environment

| Key | Value |
|-----|-------|
| affinity_cpus | 6 |
| benchmark_dir | /mnt/bench/katana_fresh_20260314/build/perf-e2e/benchmark |
| build_dir | /mnt/bench/katana_fresh_20260314/build/perf-e2e |
| cmake | CMAKE_BUILD_TYPE=RelWithDebInfo; CMAKE_CXX_COMPILER=/usr/bin/c++; CMAKE_CXX_FLAGS=; CMAKE_CXX_FLAGS_RELEASE=-O3 -DNDEBUG |
| cpu_model | AMD Ryzen 5 5600 6-Core Processor |
| hostname | visage |
| logical_cores | 6 |
| lscpu_brief | Architecture:                            x86_64; CPU(s):                                  6; Model name:                              AMD Ryzen 5 5600 6-Core Processor; Thread(s) per core:                      1; Core(s) per socket:                      6; Socket(s):                               1; NUMA node0 CPU(s):                       0-5 |
| machine | x86_64 |
| physical_cores | 6 |
| platform | Linux |
| platform_release | 6.8.0-101-generic |
| platform_version | #101-Ubuntu SMP PREEMPT_DYNAMIC Mon Feb  9 10:15:05 UTC 2026 |
| python | 3.12.3 |
| wrk_binary | /usr/bin/wrk |

---

## Quality Gates

- CV warning threshold: 20.00%
- Noisy metrics: 0
- Severely noisy metrics: 0

---

## E2E Summary

> **Note**: For pipeline stages, `wrk` latency metrics reflect one scripted batch/request() call,
> not isolated single-request service time. Throughput and error-free completion are the primary
> comparable signals across different pipeline depths.

| Stage | Profile | Benchmark | Workers | wrk t/c | Depth | Duration | Throughput | Avg Latency | p50 | p95 | p99 | Data Rate | Errors |
|-------|---------|-----------|---------|---------|-------|----------|------------|-------------|-----|-----|-----|-----------|--------|
| 9 | canonical | wrk hello_world GET / depth10 | 4 | 4/512 | 10 | 10s | 1.5M req/sec | 3130.000 us | 2114.000 us | 9329.000 us | 16423.000 us | 150.3M bytes/sec | 0 |
| 10 | canonical | wrk compute_api POST /compute/sum depth10 | 4 | 4/512 | 10 | 10s | 1.1M req/sec | 3950.000 us | 2900.000 us | 10802.000 us | 17443.000 us | 101.5M bytes/sec | 0 |

---

## HTTP Load Benchmark (hello_world_server canonical pipeline via wrk)

_Runs: 5 | Aggregation: median_

Canonical low-latency pipelined GET profile for hello_world_server

| Config | Value |
|--------|-------|
| bench_workers | 4 |
| kind | wrk_http |
| pipeline_depth | 10 |
| port | 18080 |
| profile | canonical |
| server_target | hello_world_server |
| wrk_connections | 512 |
| wrk_duration_sec | 10 |
| wrk_script | test/load/scripts/hello_pipeline.lua |
| wrk_threads | 4 |
| wrk_url | http://127.0.0.1:{port}/ |

| Benchmark | Throughput | Data Rate | Latency avg | Latency p50 | Latency p95 | Latency p99 | Latency p999 | Latency max | Errors |
|-----------|------------|-----------|-------------|-------------|-------------|-------------|--------------|-------------|--------|
| wrk hello_world GET / depth10 | 1.5M req/sec | 150.3M bytes/sec | 3130.000 us | 2114.000 us | 9329.000 us | 16423.000 us | 27899.000 us | 43180.000 us | 0 |

### Throughput Stability (Across Repeated Runs)

| Benchmark | Mean | Stddev | CV | 95% CI | Min | p50 | p95 | Max |
|-----------|------|--------|----|--------|-----|-----|-----|-----|
| wrk hello_world GET / depth10 | 1.5M | 5.2K | 0.35% | 4.5K | 1.5M | 1.5M | 1.5M | 1.5M |

### Latency Stability (Across Repeated Runs)

| Benchmark | Metric | Mean | Stddev | CV | 95% CI | p50 | p95 | Max |
|-----------|--------|------|--------|----|--------|-----|-----|-----|
| wrk hello_world GET / depth10 | avg us | 3160.000 | 71.274 | 2.26% | 62.475 | 3130.000 | 3248.000 | 3250.000 |

### Data Throughput Stability (bytes/sec)

| Benchmark | Mean | Stddev | CV | 95% CI | Min | p50 | p95 | Max |
|-----------|------|--------|----|--------|-----|-----|-----|-----|
| wrk hello_world GET / depth10 | 150.1M bytes/sec | 525.6K bytes/sec | 0.35% | 460.7K bytes/sec | 149.2M bytes/sec | 150.3M bytes/sec | 150.7M bytes/sec | 150.8M bytes/sec |

---

## HTTP Load Benchmark (compute_api canonical pipeline via wrk)

_Runs: 5 | Aggregation: median_

Canonical low-latency pipelined POST profile for compute_api

| Config | Value |
|--------|-------|
| bench_workers | 4 |
| kind | wrk_http |
| pipeline_depth | 10 |
| port | 18081 |
| profile | canonical |
| server_target | compute_api |
| wrk_connections | 512 |
| wrk_duration_sec | 10 |
| wrk_script | test/load/scripts/compute_sum_pipeline.lua |
| wrk_threads | 4 |
| wrk_url | http://127.0.0.1:{port}/ |

| Benchmark | Throughput | Data Rate | Latency avg | Latency p50 | Latency p95 | Latency p99 | Latency p999 | Latency max | Errors |
|-----------|------------|-----------|-------------|-------------|-------------|-------------|--------------|-------------|--------|
| wrk compute_api POST /compute/sum depth10 | 1.1M req/sec | 101.5M bytes/sec | 3950.000 us | 2900.000 us | 10802.000 us | 17443.000 us | 24797.000 us | 40357.000 us | 0 |

### Throughput Stability (Across Repeated Runs)

| Benchmark | Mean | Stddev | CV | 95% CI | Min | p50 | p95 | Max |
|-----------|------|--------|----|--------|-----|-----|-----|-----|
| wrk compute_api POST /compute/sum depth10 | 1.1M | 13.0K | 1.23% | 11.4K | 1.0M | 1.1M | 1.1M | 1.1M |

### Latency Stability (Across Repeated Runs)

| Benchmark | Metric | Mean | Stddev | CV | 95% CI | p50 | p95 | Max |
|-----------|--------|------|--------|----|--------|-----|-----|-----|
| wrk compute_api POST /compute/sum depth10 | avg us | 3914.000 | 65.909 | 1.68% | 57.772 | 3950.000 | 3984.000 | 3990.000 |

### Data Throughput Stability (bytes/sec)

| Benchmark | Mean | Stddev | CV | 95% CI | Min | p50 | p95 | Max |
|-----------|------|--------|----|--------|-----|-----|-----|-----|
| wrk compute_api POST /compute/sum depth10 | 101.2M bytes/sec | 1.2M bytes/sec | 1.23% | 1.1M bytes/sec | 98.8M bytes/sec | 101.5M bytes/sec | 102.2M bytes/sec | 102.2M bytes/sec |

---

## Baseline Comparison

Baseline not loaded or incompatible format.

---

## Running Benchmarks

```bash
# Build benchmark targets
cmake --preset bench
cmake --build build/bench -j$(nproc)

# Run all benchmarks
./scripts/run_benchmarks.py

# Run full micro + wrk-based E2E pipeline
./scripts/run_benchmarks.py --include-e2e

# Recommended repeat policy with explicit quality gate
./scripts/run_benchmarks.py --aggregation median --stage-repeat 1=20 --cv-threshold-pct 15

# Point the runner at a custom build tree or wrk binary
KATANA_BENCH_BUILD_DIR=build/bench-wsl KATANA_WRK_BIN=wrk ./scripts/run_benchmarks.py --include-e2e

# Collect perf counters (requires perf permissions)
./scripts/run_benchmarks.py --perf-stat

# Compare against a baseline
./scripts/run_benchmarks.py --compare benchmarks/baseline.json --fail-on-regression

# Run specific stages
./scripts/run_benchmarks.py --stage 1 2 9 10

# Run individual benchmarks
./build/bench/benchmark/codegen_quality_benchmark
./build/bench/benchmark/serialize_benchmark
./build/bench/benchmark/router_benchmark
./build/bench/benchmark/performance_benchmark
```
