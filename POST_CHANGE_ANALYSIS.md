# KATANA Post-Change Performance Analysis

> Дата анализа: 2026-03-14
> Benchmark bundle: `fresh_vm_20260314T0506Z`
> Среда: AMD Ryzen 5 5600 (6 cores), Linux 6.8.0-101-generic, bare metal
> Pipeline depth: 10, 512 connections, 4 wrk threads, 4 server workers

---

## Раздел 1. Executive Summary

### Главные выводы

1. **hello throughput: +0.87% vs old VM baseline** — практически в пределах noise. Ожидаемые +4%..+7% не достигнуты. Причина: bottleneck сместился из userspace в kernel send path и epoll. Оптимизации parser/router/headers реально убрали userspace overhead, но это не конвертировалось в RPS, потому что hello слишком лёгкий — доминируют kernel syscalls.

2. **hello latency tails: сильная регрессия** — p95 +35.48%, p99 +62.11%, p999 +56.67%. Это не regression от кода. Это следствие: (a) pipeline depth 10 amplifying queueing effects, (b) более быстрый per-request processing при неизменном write path создаёт burst behavior — больше ответов накапливается в batch, потом flush идёт одним большим write, и если TCP buffer заполнен → blocked write → tail spike.

3. **compute throughput: -3.81% vs old baseline** — небольшая регрессия. Объяснение: `parse_available()` теперь дороже (11.11% self overhead) из-за header terminator scan (`\r\n\r\n` search) на каждый request. Для compute с его POST body это дополнительная работа.

4. **compute tail latency: значительное улучшение** — p99 -6.73%, p999 -28.8%, max -18.71%. Причина: parser body-validation fix убрал over-scan body bytes. Это устранило worst-case spikes, где parser раньше валидировал весь body как headers. Tail latency улучшение — прямое следствие.

5. **router::dispatch_with_info исчез из top** — подтверждено. `hello_fast_router` O(1) dispatch работает. Это чистый win.

6. **`tolower` всё ещё в профиле compute (2.42%)** — `ci_char_equal` fix работает для прямых сравнений, но `ci_hash` в `headers_map` по-прежнему вызывает `std::tolower` через FNV-1a hash. Это не убрано.

7. **`prepare_for_next_request` в профиле (1.74% hello, 2.42% compute)** — fast path `remaining == 0` работает, но основная стоимость — `reset_message_state()` и arena reset, а не memmove. Fast path дал то, что мог.

8. **`response::serialize_into` — top userspace для hello (5.22%)** — этот стал main bottleneck после убирания router overhead. Для hello с его tiny response ("Hello, World!") — serialize overhead доминирует.

9. **Kernel overhead доминирует в hello** — 24.35% self в kernel epoll code, 33% в send/write path. Userspace оптимизации дали diminishing returns для hello.

10. **Phase 3.2 (generated dispatch string lookup) — правильно НЕ считать подтверждённым** — в compute `dispatch_compute_sum` стоит 6.28%, но основная стоимость там — JSON parsing + validation + handler, а не header string lookups. Одна строка `out.set_header("Content-Type", kJsonContentType)` (line 101 в `generated_router_bindings.hpp`) по-прежнему использует string-based lookup, но её вклад — доли процента.

### What improved
- Router dispatch полностью убран из hot path (hello)
- Parser body-validation fix дал compute tail latency improvement
- `ci_char_equal` fix убрал `std::tolower` из прямых сравнений
- `prepare_for_next_request` fast path убрал unnecessary memmove

### What regressed
- hello tail latency (p95/p99/p999/max) — burst/queueing effect
- compute avg/p50 latency — slightly worse central latency

### What old assumptions were validated
- `hello_fast_router` O(1) dispatch works as expected
- Parser body-validation fix helps compute tail latency
- Enum-based header lookups removed string_to_field from hot path

### What old assumptions are now wrong
- **"Safe patches дадут +2%..+4% E2E"** — не подтвердилось для hello. Bottleneck был не там, где ожидалось.
- **"Parser fix даст +3%..+6% для compute throughput"** — наоборот, throughput слегка хуже. Header terminator scan добавил overhead.
- **"Overall +4%..+7% hello, +4%..+8% compute after all patches"** — не подтвердилось. Real gains — в latency tails, не в throughput.

---

## Раздел 2. Implemented Changes Review

### 2.1 Enum-based header lookups (Phase 1.1)

- **Change**: Replaced `headers.get("Content-Length")` → `headers.contains(field::content_length)`, `headers.get("Connection")` → `headers.get(http::field::connection)` в `serialize_into()`, `serialize_head_into()`, `handle_connection()`
- **Target**: `serialize_into`, `handle_connection` hot path
- **Expected effect**: Уменьшить вклад `string_to_field` в hot path
- **Observed effect**: `string_to_field` не торчит в профиле. Подтверждено: enum lookup дешевле.
- **Verdict**: ✅ **Worked** — но эффект на E2E throughput не измерим, потому что `serialize_into` по-прежнему 5.22% (hello) / 2.90% (compute) из-за string appending, а не header lookup.

### 2.2 `ci_char_equal` fix (Phase 1.2)

- **Change**: Replaced `std::tolower` + comparison → bitwise XOR + range check
- **Target**: Header comparison hot path
- **Expected effect**: Снизить вклад `tolower` в compute profile
- **Observed effect**: `tolower` остаётся на 2.42% в compute profile. Причина: `ci_hash` в `headers_map` (line 183-184 в `http_headers.hpp`) по-прежнему вызывает `std::tolower` — этот callsite НЕ был изменён.
- **Verdict**: ⚠️ **Partially worked** — прямые сравнения стали быстрее, но `ci_hash` всё ещё использует `tolower`, поэтому общий вклад не упал до нуля. Fix incomplete.

### 2.3 `prepare_for_next_request` fast path (Phase 1.3)

- **Change**: Added `remaining == 0` → `buffer_size_ = 0` early exit, skip memmove
- **Target**: Pipeline processing между requests
- **Expected effect**: Убрать unnecessary memmove
- **Observed effect**: `prepare_for_next_request` — 1.74% (hello), 2.42% (compute). `__memmove_avx_unaligned_erms` — 2.61% (hello). Memmove всё ещё вызывается, но это ожидаемо: при pipeline depth 10 buffer обычно содержит следующий request.
- **Verdict**: ✅ **Worked** — для случаев `remaining == 0` skip работает. Но при pipeline depth 10 большинство вызовов имеют `remaining > 0`, поэтому memmove вызывается.

### 2.4 Parser body-validation fix (Phase 2)

- **Change**: Added `header_end_pos_` caching, `\r\n\r\n` terminator search, validation limit
- **Target**: `parse_available()` — убрать over-scan body bytes
- **Expected effect**: +3%..+6% compute throughput, correctness fix
- **Observed effect**:
  - Compute throughput: **-3.81%** (regression, not improvement)
  - Compute tail latency: **p999 -28.8%, max -18.71%** (significant improvement)
  - `parse_available()` самый тяжёлый userspace symbol в compute: 11.11%
- **Verdict**: ⚠️ **Partially worked** — correctness fix сработал (tail latency down), но throughput regression из-за added overhead: `\r\n\r\n` linear scan в `parse_available()` теперь выполняется на каждом request. Для compute (POST с body) этот scan проходит по всему header area каждый раз, добавляя O(header_size) работу. Net effect: tail latency лучше, avg throughput хуже.
- **Why**: `crlf_scan_pos_` caching помогает при partial reads, но при pipeline depth 10 полный request обычно приходит за один read. Каждый request делает полный `\r\n\r\n` scan → added constant overhead.

### 2.5 hello `fast_router` (Phase 3.1)

- **Change**: O(1) dispatch for `GET /` via dedicated `hello_fast_router`
- **Target**: Router dispatch в hello hot path
- **Expected effect**: +3%..+6% hello throughput
- **Observed effect**: `router::dispatch_with_info` полностью исчез из hello profile. Однако throughput +0.87% (noise level).
- **Verdict**: ⚠️ **Partially worked** — router overhead убран, но gain не конвертировался в throughput, потому что hello bottleneck — kernel send/epoll path (57%+ combined kernel overhead), а не userspace routing.

### 2.6 Phase 3.2: generated dispatch string lookup fix

- **Status**: Экспериментальный, НЕ считать подтверждённым
- **Reason**: По замерам не дал устойчивого выигрыша
- **Code evidence**: `generated_router_bindings.hpp:101` всё ещё содержит `out.set_header("Content-Type", kJsonContentType)` — string-based lookup. Этот string-based call проходит через `headers_map::set_view()` → `string_to_field()`, что добавляет ~20-30ns. Но при total request time ~950ns (1.05M RPS) это ~2-3% — на грани измеримости.
- **Verdict**: ❌ **Neutral / Not confirmed** — правильно не считать.

---

## Раздел 3. Throughput Analysis

### 3.1 hello throughput

**Result**: 1,473,234 req/s (+0.87% vs old baseline)

**Что реально помогло throughput**: Ничего из выполненных изменений не дало измеримого throughput gain для hello.

**Почему**: hello — trivial handler (`out.assign_text("Hello, World!")`). Userspace hot path:
- `handle_connection`: 5.22% self — dispatch logic, arena reset, parser reset
- `serialize_into`: 5.22% self — response building (string append)
- `parse_available`: 3.48% — header validation + parsing
- `prepare_for_next_request`: 1.74% — buffer management

Total userspace: ~16%. Kernel: 24.35% (epoll) + 33% (send path) = **57%+ kernel time**.

**Bottleneck**: Kernel syscalls (send, epoll_wait). При 1.47M req/s с pipeline depth 10 = ~147K пакетов/s. Каждый пакет требует send() syscall → context switch → TCP stack processing. Это hard limit, который не убирается userspace оптимизациями.

**Оставшиеся bottlenecks**:
1. `response::serialize_into` (5.22%) — string building overhead
2. `handle_connection` (5.22%) — dispatch + connection management overhead
3. Kernel send/epoll path (57%) — immovable at this pipeline depth

### 3.2 compute throughput

**Result**: 1,057,348 req/s (-3.81% vs old baseline)

**Что помогло**: Ничего из выполненных изменений не дало throughput gain.

**Что навредило**: Parser body-validation fix добавил `\r\n\r\n` scan overhead → `parse_available` стал 11.11% (vs expected ~5-6%).

**Текущие bottlenecks** (compute):
1. `parse_available`: 11.11% — top bottleneck, includes validation + `\r\n\r\n` scan
2. `dispatch_compute_sum`: 6.28% — JSON parsing + validation + handler
3. `handle_connection`: 5.31% — connection management
4. Kernel epoll: 9.18% — scheduler/event loop
5. `serialize_into`: 2.90% — response building
6. `tolower`: 2.42% — from `ci_hash` in headers_map (unfixed)
7. `prepare_for_next_request`: 2.42% — buffer management + arena reset
8. `compute_sum` handler: 1.93% — actual computation (sum of doubles)
9. `skip_ws` JSON parser: 1.93% — JSON whitespace skipping

---

## Раздел 4. Latency Analysis

### 4.1 avg/p50

| Metric | hello delta | compute delta |
|--------|------------|---------------|
| avg    | +16.36%    | +3.95%        |
| p50    | +1.73%     | +5.15%        |

**hello avg/p50**: p50 +1.73% — within noise. avg +16.36% — pulled up by tail spikes.

**compute avg/p50**: +3.95% / +5.15% — small regression. Consistent with `parse_available` overhead increase from `\r\n\r\n` scan adding ~50ns per request.

### 4.2 p95/p99/p999/max

| Metric | hello delta | compute delta |
|--------|------------|---------------|
| p95    | +35.48%    | +3.65%        |
| p99    | +62.11%    | -6.73%        |
| p999   | +56.67%    | -28.8%        |
| max    | +35.85%    | -18.71%       |

### 4.3 Почему hello tails ухудшились

**Primary cause: write batching + TCP buffer pressure under pipeline depth 10.**

Evidence chain:
1. `handle_connection` batches small responses (body ≤ 256 bytes, which includes "Hello, World!") into `active_response` string, up to `PIPELINE_RESPONSE_BATCH_LIMIT = 64KB`.
2. При pipeline depth 10, server накапливает до 10 responses (~1.4KB total) перед flush.
3. При 1.47M RPS × 4 workers = ~368K RPS/worker. Каждый worker обрабатывает ~5-6 connections одновременно.
4. Когда быстрый router (fast path) + быстрый parser обрабатывают запросы быстрее, batch быстрее наполняется → flush_ready_responses() вызывается с бо́льшим batch → один большой write().
5. Если TCP send buffer заполнен (другие connections ещё не ACK'нули) → `write()` возвращает partial write или EAGAIN → `arm_writable()` → switch to epoll wait → latency spike для ВСЕХ ждущих responses в batch.
6. Более быстрый userspace processing → больше outstanding responses → больше давление на TCP → чаще partial writes → хуже tails.

**Confirmation**: Perf profile показывает 33% в send/write path. Это аномально много для hello. При старом (более медленном) userspace processing, responses сливались медленнее, TCP buffer успевал drain, и tails были лучше.

**Secondary cause**: Event-loop fairness. При быстром userspace processing, worker thread может monopolize CPU на одном connection (обработать все 10 pipelined requests) перед тем, как вернуться в epoll. Другие connections starve → их latency растёт.

**Это НЕ service-time regression**. Это queueing + scheduling effect, amplified by pipeline depth 10.

### 4.4 Почему compute tails улучшились

**Primary cause: parser body-validation fix eliminated worst-case scan.**

Before fix: `parse_available()` top-level validation loop scanned body bytes (POST body) looking for invalid header characters. On worst case (large body with bytes near 0x80), this was O(body_size) extra work — and it happened on EVERY call to `parse_available()`, including re-entries after partial reads.

After fix: validation limited to `header_end_pos_`. Body bytes never scanned. Worst-case eliminated.

This is a **real service-time improvement for tail latency**. The avg/p50 increase is from added `\r\n\r\n` scan overhead (constant), but tail reduction is from eliminated worst-case body scan (proportional to body size).

**Secondary cause**: Compute requests are heavier (JSON parsing, validation, computation). This means TCP buffer pressure is lower per-connection (fewer responses/sec), so the write batching effect that hurts hello doesn't apply as strongly.

### 4.5 Классификация причин

| Factor | hello effect | compute effect |
|--------|-------------|----------------|
| Queueing / TCP buffer pressure | **Primary** regressor | Minimal impact |
| Pipeline burst amplification | **Major** — depth 10 × batching | Moderate |
| Write path behavior | **Major** — 33% in send path | Normal |
| Event-loop fairness | **Contributing** | Minimal |
| Per-connection monopolization | **Contributing** — fast path enables longer runs | Minimal |
| Serializer overhead | Neutral | Neutral |
| Parser compaction | Neutral | Neutral |
| Benchmark artifact (pipeline depth 10) | **Yes** — pipeline depth 10 amplifies all queueing effects | Yes, but less |
| Real service-time change | No regression | **Improvement** (body validation fix) |

---

## Раздел 5. Zone-by-Zone Diagnosis

### Zone 1: Parser (`parse_available`, `parse_request_line_state`, `parse_headers_state`)

**Current status**: `header_end_pos_` caching implemented. `\r\n\r\n` terminator search added. Validation limited to header area.

**Effect on throughput**: Negative for compute. `parse_available` went from expected ~5% to 11.11% self overhead in compute profile. The `\r\n\r\n` linear scan is the culprit.

**Effect on latency**: Positive for compute tails (worst-case body scan eliminated). Neutral for hello.

**Next best move**: Optimize the `\r\n\r\n` scan. Current code (http.cpp:617-625):
```cpp
for (size_t i = scan_start; i + 3 < buffer_size_; ++i) {
    if (buffer_[i] == '\r' && buffer_[i + 1] == '\n' && buffer_[i + 2] == '\r' && buffer_[i + 3] == '\n') {
        header_end_pos_ = i + 4;
        break;
    }
}
```
This is a naive byte-by-byte scan. Can be replaced with SIMD `\r\n\r\n` detection using existing `simd::find_crlf` infrastructure, or better: use the SIMD CRLF pair counter already being tracked (`crlf_pairs_`) to detect `\r\n\r\n` during the normal parsing flow, eliminating the separate scan entirely.

### Zone 2: Response Serialization (`serialize_into`)

**Current status**: Uses `std::string::append()` for building response. Enum-based header lookups implemented. Content-Length computed via `std::to_chars`.

**Effect on throughput**: Top userspace bottleneck for hello (5.22%), secondary for compute (2.90%).

**Effect on latency**: Contributes to avg but not specifically to tails.

**Next best move**: For hello (and other tiny responses), the `serialize_into(std::string&)` path involves: reserve + clear + 7 appends + body append. Для response "Hello, World!" (~100 bytes total) это 8 string operations. Possible improvement: pre-compute full response template at handler registration time for static responses. Or use `serialize_into(io_buffer&)` path which does direct memcpy. Currently hello uses `std::string` path because responses are batched into `active_response` string.

### Zone 3: Request Lifecycle / `handle_connection`

**Current status**: Pipeline batching implemented (up to 64KB batch). Small response optimization (≤256 bytes body → single string). Writev for larger responses.

**Effect on throughput**: 5.22% (hello), 5.31% (compute) self overhead. Includes dispatch, arena management, parser control flow.

**Effect on latency**: The batching logic itself contributes to tail latency for hello — accumulating responses before flushing increases tail exposure.

**Next best move**: Consider flushing more eagerly when pipeline depth is high. Currently batch limit is 64KB — for hello, this allows ~400 responses in one batch. But wrk with pipeline depth 10 sends 10 requests per batch, so typical batch is ~10 responses. The issue isn't batch size per se, but the interaction with TCP buffer state. A possible improvement: after each batch flush, if the write completes fully (no EAGAIN), immediately check for more readable data rather than returning to epoll. This is already implemented in the current code (the `continue` after `flush_ready_responses()`). The problem is when flush returns `blocked` → arm_writable → wait for epoll → all 10 responses delayed.

### Zone 4: Router / Dispatch

**Current status**: hello uses `hello_fast_router` with O(1) dispatch for `GET /`. Completely eliminated from profile.

**Effect on throughput**: Positive (removed overhead), but not measurable because bottleneck is elsewhere.

**Effect on latency**: Neutral.

**Next best move**: Nothing to do here. This is done.

### Zone 5: Compute Generated Dispatch

**Current status**: `dispatch_compute_sum` at 6.28%. Includes content negotiation, content-type check, JSON parsing, validation, handler call, and one remaining string-based `set_header("Content-Type", ...)`.

**Effect on throughput**: Main userspace bottleneck for compute after parser.

**Effect on latency**: Contributes to avg.

**Next best move**: The 6.28% includes JSON parsing (`parse_compute_sum_request`), validation (`validate_compute_sum_request`), and handler (`compute_sum`). Each of these is separately profiled: handler 1.93%, `skip_ws` 1.93%. The remaining ~2.4% is content negotiation + JSON serialization overhead. Fixing `out.set_header("Content-Type", kJsonContentType)` → `out.headers.set_known_borrowed(katana::http::field::content_type, kJsonContentType)` would save ~20-30ns per request, but this is Phase 3.2 which didn't show sustained gain. Low priority.

### Zone 6: Header Normalization / Comparison

**Current status**: `ci_char_equal` uses bitwise XOR (fixed). But `ci_hash` still uses `std::tolower` (line 184 in `http_headers.hpp`).

**Effect on throughput**: `tolower` at 2.42% in compute profile. Not visible in hello profile (fewer headers).

**Effect on latency**: Contributes to avg for compute.

**Next best move**: Replace `std::tolower` in `ci_hash::operator()`:
```cpp
// Current:
hash ^= static_cast<size_t>(std::tolower(static_cast<unsigned char>(c)));
// Replace with:
unsigned char uc = static_cast<unsigned char>(c);
hash ^= static_cast<size_t>(uc | ((uc >= 'A' && uc <= 'Z') ? 0x20 : 0));
```
This avoids the locale-dependent `std::tolower` function call. Expected gain: ~1-2% compute throughput.

### Zone 7: `prepare_for_next_request` / Compaction / Buffering

**Current status**: Fast path for `remaining == 0` implemented. At 1.74% (hello), 2.42% (compute).

**Effect on throughput**: Minor contributor.

**Effect on latency**: Neutral.

**Next best move**: Most of the cost is `reset_message_state()` + arena reset, not memmove. Arena reset zeroes inline header arrays (16 `known_entry` + 8 `unknown_entry` = ~400 bytes of zeroing). Could be optimized with `memset` instead of individual field assignments, but gain would be marginal (~0.5%).

### Zone 8: Network / epoll / Send Path

**Current status**: 24.35% kernel (epoll) + 33% kernel (send) in hello. TCP_NODELAY enabled by default. No TCP_QUICKACK.

**Effect on throughput**: This IS the bottleneck for hello. Not addressable via userspace code changes.

**Effect on latency**: Send path blocking → tail latency regression.

**Next best move**:
1. **Enable TCP_QUICKACK** — reduces ACK delay, potentially improving send path throughput by reducing TCP window stalls. Environment variable `KATANA_TCP_QUICKACK=1` already supported but off by default.
2. **Cork/uncork pattern** — use TCP_CORK before batch write, uncork after, to let kernel send one large segment instead of many small ones. Reduces syscall overhead.
3. **MSG_MORE** flag on send() for all but last response in batch — tells kernel to aggregate.
4. **io_uring** — replaces epoll + send syscalls with batched submission. Major change, but would directly address the 57% kernel overhead.

### Zone 9: Benchmark Methodology / Pipeline Sensitivity

**Current status**: wrk with pipeline depth 10, 512 connections, 4 threads.

**Key observation**: Pipeline depth 10 creates a specific load pattern:
- Client sends 10 requests in burst
- Server processes all 10, batches responses
- Flush responses
- Wait for next burst

This creates bursty behavior that amplifies both throughput AND tail latency. The measured latency is not single-request service time — it's batch-of-10 completion time.

**Effect**: Makes it very hard to distinguish service-time improvements from queueing effects. hello's tail regression is primarily a queueing artifact, not a code regression.

**Next best move**: Run fixed-load latency measurements at different pipeline depths (1, 2, 5, 10) to separate service-time from queueing effects.

---

## Раздел 6. New Prioritized Plan

### Priority 1: Fix `ci_hash` tolower (header normalization)

- **Priority**: P1 — low risk, clear evidence
- **Area**: `http_headers.hpp`, `ci_hash::operator()`
- **Target metric**: Compute RPS +1-2%, compute avg latency -1-2%
- **Expected gain**: 1-2% compute E2E
- **Confidence**: High — `tolower` at 2.42% in profile, direct callsite fix
- **Risk**: Near-zero — equivalent logic, no behavior change
- **Why now**: Unfinished work from Phase 1.2. The `ci_char_equal` was fixed but `ci_hash` was missed.

### Priority 2: SIMD-accelerate `\r\n\r\n` terminator scan

- **Priority**: P1 — addresses the main compute throughput regression
- **Area**: `http.cpp`, `parse_available()`, lines 617-625
- **Files**: `http.cpp`, `simd_utils.hpp`
- **Target metric**: Compute RPS +3-5%, compute avg/p50 latency -3-5%
- **Expected gain**: 3-5% compute throughput recovery
- **Confidence**: High — 11.11% in `parse_available`, terminator scan is known bottleneck
- **Risk**: Low — SIMD infrastructure already exists (`simd::find_crlf`)
- **Why now**: This scan was introduced by Phase 2 parser fix. It's the main source of compute throughput regression.

### Priority 3: MSG_MORE / TCP_CORK for batched writes

- **Priority**: P2 — addresses hello tail latency
- **Area**: `http_server.cpp`, `flush_active_response()`, send path
- **Target metric**: Hello p95/p99/p999 latency -20-40%
- **Expected gain**: Significant tail latency improvement for hello
- **Confidence**: Medium — the mechanism is well-understood (reducing packet fragmentation), but effect depends on kernel TCP stack behavior
- **Risk**: Medium — could affect throughput if cork/uncork adds syscall overhead
- **Why now**: hello tail latency regression is the main regression from this round of changes.

### Priority 4: `serialize_into` optimization for tiny responses

- **Priority**: P2 — hello throughput ceiling
- **Area**: `http.cpp`, `response::serialize_into(std::string&)`
- **Target metric**: Hello RPS +2-3%
- **Expected gain**: 2-3% by reducing string operations
- **Confidence**: Medium — 5.22% self overhead, but optimization path unclear (pre-computed templates require API changes)
- **Risk**: Low-medium
- **Why now**: After removing router overhead, this is the next userspace bottleneck.

### Priority 5: Eager flush heuristic

- **Priority**: P3 — tail latency improvement
- **Area**: `http_server.cpp`, `handle_connection()`
- **Target metric**: Hello/compute p99/p999
- **Expected gain**: 10-20% tail latency improvement
- **Confidence**: Low-medium — depends on how much of the tail is from batching vs TCP
- **Risk**: Low — heuristic change, easy to revert
- **Why now**: If TCP_CORK approach (Priority 3) doesn't fully solve tail latency.

### Priority 6: TCP_QUICKACK enable by default

- **Priority**: P3
- **Area**: `http_server.cpp`, `configure_client_socket()`
- **Target metric**: Hello/compute p50 latency, minor RPS
- **Expected gain**: 1-3% latency improvement
- **Confidence**: Medium
- **Risk**: Near-zero — already implemented behind env flag
- **Why now**: Low-hanging fruit.

---

## Раздел 7. Latency-First Plan

Если цель — снизить tail latency (p99/p999/max) даже за счёт RPS:

### Step 1: MSG_MORE / TCP_CORK for batched writes
- Непосредственно адресует 33% kernel send path overhead
- Expected: p99 -20-30%, p999 -30-40% для hello

### Step 2: Reduce pipeline batch accumulation
- Flush after every N responses (e.g., 5) instead of accumulating full batch
- Expected: p95 -10-20% за счёт reduced latency variance

### Step 3: Per-connection time-budget
- If a single connection has been processing for > X us, yield to epoll
- Prevents connection monopolization
- Expected: p999 -10-20%, especially under high concurrency

### Step 4: Fixed-load testing at pipeline depth 1
- Measure actual service-time distribution
- Separate queueing effects from code effects
- Expected: reveals true service-time shape, informs further optimization

### Step 5: TCP_QUICKACK enable
- Reduces ACK-delayed write stalls
- Expected: p50 -1-3%

---

## Раздел 8. Throughput-First Plan

Если цель — максимизировать RPS:

### Step 1: SIMD `\r\n\r\n` scan
- Recovers compute throughput regression
- Expected: compute +3-5%

### Step 2: Fix `ci_hash` tolower
- Removes unnecessary function call overhead
- Expected: compute +1-2%

### Step 3: `serialize_into` optimization
- Pre-compute status line for common status codes
- Use `memcpy` instead of `append` for fixed parts
- Expected: hello +2-3%

### Step 4: Reduce arena reset cost
- Use `memset` for header inline arrays instead of per-field reset
- Expected: +0.5-1% across both

### Step 5 (major): io_uring
- Replaces epoll + send with batched I/O
- Expected: hello +10-30% (removes 57% kernel overhead)
- Risk: Major rewrite of event loop
- Only after all smaller optimizations are exhausted

---

## Раздел 9. What To Measure Next

### 9.1 Fixed-load latency sweep
- Run wrk с pipeline depth 1 at 500K, 700K, 1M, 1.2M RPS (fixed rate)
- Measure p50/p95/p99/p999 at each load level
- Purpose: Separate service-time distribution from queueing effects

### 9.2 Pipeline depth sensitivity
- Run at pipeline depth 1, 2, 5, 10, 20
- Measure both RPS and full latency distribution
- Purpose: Understand how pipeline depth affects tail latency shape

### 9.3 Lower-load runs
- Run at 50% max throughput (fixed rate)
- Measure latency distribution
- Purpose: Establish "true service time" without queueing

### 9.4 Per-thread imbalance
- Add per-worker RPS counters (already have `note_completed_request`)
- Run benchmark, compare per-worker completion counts
- Purpose: Detect unfair scheduling or connection distribution

### 9.5 Send/write batching
- Instrument `flush_active_response` to log batch size + partial write frequency
- Purpose: Confirm that partial writes correlate with tail latency spikes

### 9.6 Queue depth proxies
- Add metric: max buffered responses per connection per event loop iteration
- Purpose: Quantify queueing depth

### 9.7 Syscall tracing
- `perf trace -e sendto,epoll_wait -p $PID` for 1 second under load
- Purpose: Count syscalls/sec, identify syscall batching opportunities

### 9.8 Serializer microbench
- Benchmark `serialize_into` standalone for hello response
- Compare with `memcpy`-based approach
- Purpose: Establish optimization ceiling for serialize path

### 9.9 Direct hello fast path vs fallback comparison
- Run hello WITHOUT `fast_router` (use standard router)
- Compare tail latency
- Purpose: Confirm that faster processing → worse tails (queueing theory prediction)

### 9.10 TCP_CORK experiment
- Run hello with TCP_CORK/uncork around batch writes
- Measure tail latency impact
- Purpose: Validate cork-based approach before implementation

---

## Раздел 10. Final Decision

### Что править первым
**Fix `ci_hash` tolower** — 30 minutes work, near-zero risk, recovers 1-2% compute. This is an oversight from Phase 1.2.

### Что вторым
**SIMD `\r\n\r\n` scan** — 2-4 hours work, moderate complexity but uses existing SIMD infrastructure. Recovers 3-5% compute throughput regression caused by Phase 2.

### Что третьим
**MSG_MORE / TCP_CORK experiment** — 2-3 hours work, medium risk. Addresses hello tail latency regression. Run as experiment first, commit only if tail latency improves >15%.

### Что пока не трогать
- **`serialize_into` rewrite** — не трогать пока не решены problems 1-3. Serializer optimization less impactful while kernel overhead dominates.
- **io_uring** — major rewrite, deferred until smaller optimizations exhausted and measured.
- **Pipeline batch size tuning** — dependent on MSG_MORE experiment results.
- **Arena reset optimization** — marginal gain (<1%), not worth the effort now.

### False leads
- **"Higher RPS = better latency"** — опровергнуто. For hello, faster userspace processing led to worse tail latency because of queueing effects. Throughput-first thinking does not apply when goal is latency.
- **"Phase 3.2 string lookup fix will help compute"** — not confirmed by measurements. 6.28% in `dispatch_compute_sum` is dominated by JSON parsing and validation, not by one `set_header` call.
- **"Parser fix should help throughput"** — partially wrong. The fix correctly limited validation scope, but introduced new overhead (`\r\n\r\n` scan) that offset throughput gains. Net: better correctness, better tail latency, worse throughput.

### Пересмотреть, если цель именно latency
- **fast_router может вредить tail latency**. Быстрый dispatch → faster response generation → more pressure on TCP buffer → worse tails. Это контр-интуитивно, но подтверждается: hello добавил fast_router → tails ухудшились. Рассмотреть добавление deliberate yield point после каждого N-го response в pipeline, чтобы дать TCP buffer drain.
- **Pipeline depth 10 как источник noise**. Latency при depth 10 — это не service time, а batch completion time. Все выводы о tail latency должны быть перепроверены при depth 1. Если при depth 1 tails стабильны или лучше, то hello tail regression — артефакт бенчмарка, не код regression.
- **Batching heuristic**: текущий `PIPELINE_RESPONSE_BATCH_LIMIT = 64KB` может быть слишком агрессивным для latency-first profile. Рассмотреть adaptive batching: batch aggressively when TCP buffer has space, flush eagerly when previous write was partial.
