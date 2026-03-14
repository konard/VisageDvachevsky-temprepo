# KATANA Optimization Implementation Plan (Updated)

На основе PERFORMANCE_REVIEW.md, DEEP_ANALYSIS_REPORT.md и FINAL_VERDICT.md.

**This is an updated version** incorporating corrections from the final technical adjudicator verdict. All inflated estimates have been corrected, weak items dropped/deferred, and the parser/body-validation fix has been redesigned with a state-machine-friendly approach (no per-call `find_header_terminator()` scan).

**Key corrections applied:**
- Ir% ≠ wallclock% (systematic 1.5–3x overestimate in original plan)
- Gains are not additive (Amdahl's Law)
- I/O bound fraction unknown (sets ceiling on CPU optimization gains)
- VirtualBox measurement noise floor ~3%

---

## Updated Phase 0: Verification — Baseline Lock-in

### Цель
Зафиксировать воспроизводимый baseline для всех последующих сравнений.

### Действия

1. **Запустить canonical benchmarks 5 раз, взять median:**
   ```bash
   for i in 1 2 3 4 5; do
     wrk -t4 -c512 -d10s http://127.0.0.1:8080/ > hello_run_$i.txt 2>&1
   done
   for i in 1 2 3 4 5; do
     wrk -t4 -c512 -d10s -s compute_payload.lua http://127.0.0.1:8081/compute/sum > compute_run_$i.txt 2>&1
   done
   ```

2. **Снять callgrind baseline для обоих сценариев:**
   ```bash
   valgrind --tool=callgrind --callgrind-out-file=hello_baseline.callgrind ./hello_server &
   wrk -t1 -c1 -d3s http://127.0.0.1:8080/
   kill %1
   callgrind_annotate hello_baseline.callgrind > hello_baseline_annotate.txt
   ```

3. **Зафиксировать commit hash в лог.**

### Критерий успеха
- Все 5 прогонов отличаются не более чем на 10%.
- callgrind Ir детерминистичен (±0.1%).
- Файлы baseline сохранены в `benchmarks/baseline/`.

---

## Updated Phase 1: Quick Wins — 20 минут, Zero Risk

### Цель
Три точечных правки, zero-risk, суммарный ожидаемый выигрыш: **+2–4% throughput** в обоих сценариях.

**Corrected from original:** original claim was +5–8%. Correction: Ir% ≠ wallclock%. Not all `string_to_field` Ir (7.41%) comes from these 4 call sites (parser also calls it). Real saving is a fraction.

---

### 1.1 Replace string-based header lookups with `field` enum

**Файлы:**
- `http.cpp` — строка 214
- `http.cpp` — строка 278
- `http_server.cpp` — строка 418, 422

**Функции:**
- `response::serialize_into(std::string&)` — строка 214
- `response::serialize_head_into(std::string&)` — строка 278
- `handle_connection(...)` — строки 418–422

**Что заменить → на что:**

#### http.cpp:214 (serialize_into)
```diff
-    bool has_content_length = headers.get("Content-Length").has_value();
+    bool has_content_length = headers.contains(field::content_length);
```

#### http.cpp:278 (serialize_head_into)
```diff
-    bool has_content_length = headers.get("Content-Length").has_value();
+    bool has_content_length = headers.contains(field::content_length);
```

#### http_server.cpp:418–422 (handle_connection)
```diff
-        auto connection_header = req.headers.get("Connection");
+        auto connection_header = req.headers.get(http::field::connection);
         bool close_connection =
             connection_header && (*connection_header == "close" || *connection_header == "Close");

-        if (!resp.headers.get("Connection")) {
+        if (!resp.headers.contains(http::field::connection)) {
```

**Почему это поможет:**
- `get(string_view)` → `string_to_field()` → hash → bucket scan → `ci_equal_fast`.
- `get(field)` → прямой linear scan по `known_inline_` (max 16 entries), без hashing.
- `contains(field)` → `find_known_entry(f) != nullptr` — ещё быстрее.

**Realistic expected gain: +1.5–2.5% both scenarios.**
Not all 7.41% Ir from `string_to_field` comes from these 4 calls — parser also calls it. Real saving is the fraction from these specific call sites.

**Риск:** Нулевой. API уже существует и используется.

**Validation:**
- `callgrind_annotate | grep string_to_field` — Ir count should decrease by ≥15%
- `curl http://127.0.0.1:8080/` — response identical byte-for-byte
- Connection: close/keep-alive behavior unchanged

---

### 1.2 Replace `std::tolower` with branchless ASCII lowering in `ci_char_equal`

**Файл:** `http_headers.hpp` — строки 31–34

**Функция:** `ci_char_equal(char a, char b)`

```diff
 inline bool ci_char_equal(char a, char b) noexcept {
-    return std::tolower(static_cast<unsigned char>(a)) ==
-           std::tolower(static_cast<unsigned char>(b));
+    if (a == b) return true;
+    unsigned char ua = static_cast<unsigned char>(a);
+    unsigned char ub = static_cast<unsigned char>(b);
+    return (ua ^ ub) == 0x20 && ((ua | 0x20) >= 'a') && ((ua | 0x20) <= 'z');
 }
```

**Почему XOR+range check, а не простое `|0x20`:**
- `(a | 0x20) == (b | 0x20)` даёт ложные positives: `'^'` (0x5E) и `'~'` (0x7E) дадут true, `'@'` и `` '`' `` тоже.
- XOR+range check: `(ua ^ ub) == 0x20` проверяет, что байты отличаются ровно на case bit, а `(ua | 0x20) >= 'a' && <= 'z'` — что оба в диапазоне A–Z/a–z.
- Note: `ci_equal_short` и SIMD paths уже используют `|0x20` — эта pre-existing inconsistency out of scope, но should be tracked.

**Realistic expected gain: +1–2% compute, +0.5% hello.**

**Риск:** Минимальный. HTTP headers — ASCII per RFC 7230 §3.2.

**Validation:**
- `ci_char_equal('A', 'a')` → true
- `ci_char_equal('^', '~')` → false (would be true with naive `|0x20`)
- `ci_char_equal('@', '`')` → false
- `perf report` — `tolower` should disappear from compute top symbols

---

### 1.3 Optimize `prepare_for_next_request` memmove

**Файл:** `http.cpp` — строка 1152

**Функция:** `parser::prepare_for_next_request()`

```diff
 void parser::prepare_for_next_request(monotonic_arena* arena) noexcept {
     size_t remaining = buffered_bytes();
-    if (remaining > 0 && parse_pos_ > 0) {
+    if (remaining == 0) {
+        buffer_size_ = 0;
+    } else if (parse_pos_ > 0) {
         std::memmove(buffer_, buffer_ + parse_pos_, remaining);
+        buffer_size_ = remaining;
     }
-    buffer_size_ = remaining;
     reset_message_state(arena);
 }
```

**Realistic expected gain: +0.3–0.5% both.**
Marginal gain but zero risk. Trivial.

**Validation:**
- wrk with pipelining — no regression
- `valgrind --tool=memcheck` — no memory errors

---

### ~~1.3 (OLD) Add `[[gnu::always_inline]]` to `skip_ws()`~~ — **DROPPED**

**Verdict: DROP.** Effect is < 0.01% — unmeasurable noise. Call/ret overhead for 164K calls ≈ 0.5–0.8M cycles out of billions. Compiler likely already inlines at -O2/-O3. Original estimate of +1% was ~100x overestimate. Verify with `objdump -d` — if `skip_ws` doesn't appear as a separate symbol, it's already inlined.

---

### Phase 1 Summary (Updated)

| Fix | File | Effort | Realistic Gain | Confidence |
|---|---|---|---|---|
| field enum lookups | `http.cpp:214,278`, `http_server.cpp:418,422` | 5 min | +1.5–2.5% both | **High** |
| tolower → branchless | `http_headers.hpp:31-34` | 5 min | +1–2% compute, +0.5% hello | **High** |
| prepare_for_next memmove | `http.cpp:1152` | 5 min | +0.3–0.5% both | **High** |

**Суммарный ожидаемый выигрыш Phase 1: +2–4% throughput** (corrected from +5–8%).

---

## Updated Phase 2: Parser Body Validation Fix — 30 min, Requires Verification

### Цель
Устранить #1 bottleneck: parser validation loop scanning body bytes needlessly.

**Corrected estimate:** +3–6% compute, +1–2% hello (original claim was +10–15% compute).

**Correction rationale:**
- Parser Ir% in compute is 48.03%, but perf% (wallclock) is only 31.67% (ratio 0.66x)
- Body bytes ≈ 29% of total request for canonical compute payload, not 50%+
- Ir% → wallclock correction: 22% Ir × 29% body fraction × 0.66 ratio ≈ 4.2%

---

### Parser Fix Design

#### Current Problem

In `parser::parse_available()` (http.cpp:627–642), the validation loop runs when `state_ == request_line || state_ == headers`:

```cpp
if (state_ == state::request_line || state_ == state::headers) [[likely]] {
    size_t validation_start = validated_bytes_;
    if (validation_start > 0) {
        --validation_start;
    }
    for (size_t i = validation_start; i < buffer_size_; ++i) {
        uint8_t byte = static_cast<uint8_t>(buffer_[i]);
        if (byte == 0 || byte >= 0x80) [[unlikely]] { ... error ... }
        if (byte == '\n' && (i == 0 || buffer_[i - 1] != '\r')) [[unlikely]] { ... error ... }
    }
    validated_bytes_ = buffer_size_;
}
```

**The problem:** When a single `read()` delivers both headers and body bytes into the buffer, the validation loop scans ALL bytes up to `buffer_size_`, including body bytes. Body bytes may legitimately contain:
- UTF-8 characters (>= 0x80) — **currently incorrectly rejected** (latent bug, violates RFC 7230 §3.3)
- Null bytes — which should be allowed through to the application layer

The guard condition `state_ == request_line || state_ == headers` correctly prevents the loop from running on subsequent `parse_available()` calls after headers are fully parsed (state transitions to `body`). But on the **first** call where headers end AND body begins in the same buffer, the loop still over-scans.

Note: `parse_headers_state()` (line 723) also performs its own per-line validation (lines 728–735), providing redundant coverage for header bytes. The top-level validation loop's purpose is to pre-scan the entire buffer before entering the state machine, catching malformed bytes early. But this pre-scan does not need to cover body bytes.

#### Why NOT to use `find_header_terminator()` per call

The original implementation plan proposed calling `find_header_terminator()` inside the validation loop to determine where headers end. **This is wrong** because:

1. `find_header_terminator()` is an O(N) scan (http.cpp:84–94) — it linearly searches for `\r\n\r\n` through the entire buffer
2. Calling it on every `parse_available()` invocation adds O(N) work to a function that's already a bottleneck
3. The validation loop itself is O(N), so adding another O(N) scan may negate or reduce savings
4. `find_header_terminator()` is already called at line 646 for the MAX_HEADER_SIZE check — but only when `buffer_size_ > MAX_HEADER_SIZE`, so it doesn't always run

#### Safest Implementation Approach: State-Machine-Friendly `header_end_pos_`

Instead of scanning, **cache the end-of-headers position** as a parser state variable. The parser already discovers where headers end during normal parsing — specifically in `parse_headers_state()` at line 741 when it finds the empty line (`line.empty()`). At that point, `parse_pos_` points right after the `\r\n\r\n` terminator.

**Step-by-step approach:**

1. Add a member variable `header_end_pos_` to the parser class (initialized to 0, meaning "not yet found")
2. When `parse_headers_state()` detects the empty line (line 741), set `header_end_pos_ = parse_pos_` — this is the position immediately after `\r\n\r\n`
3. In the validation loop, use `header_end_pos_` to limit the scan range
4. Reset `header_end_pos_` in `reset_message_state()` along with other per-request state

**Why this is safe:**

The validation loop runs **before** the state machine loop (line 656). So on the first call where both headers and body arrive:
1. Validation loop runs with `header_end_pos_ == 0` → scans all bytes (same as current behavior)
2. State machine runs → `parse_headers_state()` finds empty line → sets `header_end_pos_`
3. State transitions to `body`
4. **On subsequent calls**, `state_ != request_line && state_ != headers` → validation loop doesn't run at all

Wait — this means `header_end_pos_` is set **after** the validation loop runs. So for the first call, it's still 0 and the loop scans everything. The fix only helps on subsequent calls, but those are already skipped by the state guard!

**Revised approach:** The validation loop and the state machine run in the same `parse_available()` call. The problem is that on the **first** call, the validation loop runs before the state machine discovers where headers end. We need a different strategy.

**Correct approach: Use `find_header_terminator()` ONCE, cache the result.**

The key insight from the final verdict is: don't call `find_header_terminator()` on **every** `parse_available()` call. Instead:

1. Add `header_end_pos_` member (initialized to 0)
2. In the validation loop: if `header_end_pos_ == 0`, call `find_header_terminator()` to discover it and cache it. If `header_end_pos_ != 0`, reuse cached value
3. This means `find_header_terminator()` is called **at most once** per request (on the first `parse_available()` call where the full header terminator is present in the buffer)
4. For partial headers (terminator not yet in buffer), `find_header_terminator()` returns nullptr → validation scans all bytes (correct: all bytes are headers at this point)
5. Once cached, subsequent calls (while still in `request_line`/`headers` state) use the cached position

This is safe because:
- For partial headers across multiple reads: each call scans all buffer bytes (correct — they're all header bytes)
- For headers + body in one read: first call discovers terminator, scans only header bytes. Subsequent calls in `body` state skip the validation entirely (state guard)
- For pipelined requests: `reset_message_state()` resets `header_end_pos_` to 0

#### Data/State Changes

**Add to parser class:**
```cpp
size_t header_end_pos_ = 0;  // Position after \r\n\r\n, 0 = not yet found
```

**Reset in `reset_message_state()`** (http.cpp:1124):
```cpp
header_end_pos_ = 0;
```

#### Exact Functions to Edit

1. **Parser class definition** — add `size_t header_end_pos_ = 0;` member
2. **`parser::parse_available()`** (http.cpp:627–642) — limit validation loop using cached `header_end_pos_`
3. **`parser::reset_message_state()`** (http.cpp:1124) — reset `header_end_pos_ = 0`

#### Step-by-Step Patch Sequence

##### Patch A: Add member variable

In the parser class definition, add alongside other state variables:
```diff
     size_t validated_bytes_ = 0;
+    size_t header_end_pos_ = 0;
     size_t crlf_scan_pos_ = 0;
```

##### Patch B: Reset in `reset_message_state()`

```diff
 void parser::reset_message_state(monotonic_arena* arena) noexcept {
     ...
     validated_bytes_ = 0;
+    header_end_pos_ = 0;
     crlf_scan_pos_ = 0;
```

##### Patch C: Limit validation loop

```diff
 if (state_ == state::request_line || state_ == state::headers) [[likely]] {
     size_t validation_start = validated_bytes_;
     if (validation_start > 0) {
         --validation_start;
     }
-    for (size_t i = validation_start; i < buffer_size_; ++i) {
+    // Limit validation to header bytes only. Body bytes may contain
+    // valid UTF-8 (>= 0x80) or null bytes — validating them is incorrect
+    // (latent bug: currently rejects valid RFC 7230 §3.3 body content).
+    size_t validation_limit = buffer_size_;
+    if (header_end_pos_ == 0 && buffer_size_ >= 4) {
+        const char* term = find_header_terminator(buffer_, buffer_size_);
+        if (term) {
+            header_end_pos_ = static_cast<size_t>(term - buffer_) + 4;
+        }
+    }
+    if (header_end_pos_ > 0 && header_end_pos_ < validation_limit) {
+        validation_limit = header_end_pos_;
+    }
+    for (size_t i = validation_start; i < validation_limit; ++i) {
         uint8_t byte = static_cast<uint8_t>(buffer_[i]);
         if (byte == 0 || byte >= 0x80) [[unlikely]] { ... }
         if (byte == '\n' && (i == 0 || buffer_[i - 1] != '\r')) [[unlikely]] { ... }
     }
-    validated_bytes_ = buffer_size_;
+    validated_bytes_ = validation_limit;
 }
```

**Important:** `validated_bytes_` is set to `validation_limit` (not `buffer_size_`), so if the buffer grows with more body bytes on a subsequent call, the state guard (`state_ == headers`) will be false (we're already in `body` state) and the loop won't run.

#### Edge Cases

| Edge Case | Behavior | Correct? |
|---|---|---|
| Headers + body in one read | `find_header_terminator()` finds `\r\n\r\n`, caches position. Validation scans only header bytes. Body bytes pass through. | ✅ Yes |
| Partial headers across multiple reads | `find_header_terminator()` returns nullptr → `header_end_pos_` stays 0 → scans all bytes (all are header bytes). On next read with more data, if terminator found, caches position. | ✅ Yes |
| UTF-8 bytes in body | Not scanned by validation loop → accepted. JSON parser handles them downstream. | ✅ Yes (fixes latent bug) |
| Null bytes in body | Not scanned → accepted. JSON parser will reject them. C-string consumers should be audited. | ✅ Acceptable |
| Pipelined requests | `reset_message_state()` resets `header_end_pos_ = 0` between requests. Next request starts fresh. | ✅ Yes |
| GET request (no body) | `find_header_terminator()` finds `\r\n\r\n`, validation scans headers only. No body to skip. No difference in behavior. | ✅ Yes |
| Very large headers (> MAX_HEADER_SIZE) | `find_header_terminator()` is already called at line 646 for size check. Our call at line ~632 adds one additional scan for the first `parse_available()` call only — acceptable overhead for correctness fix. | ✅ Yes |

#### Validation Checklist

- [ ] POST with UTF-8 JSON body (`{"name": "Привет"}`) → must succeed (fixes latent bug where >= 0x80 bytes were rejected)
- [ ] POST with null byte in body → parser should accept, JSON parser should reject
- [ ] GET / → identical behavior to current (no body, headers fully validated)
- [ ] Pipelined POST+POST → both requests parsed correctly
- [ ] Partial header across 2 reads → no regression
- [ ] `callgrind`: `parse_available` Ir in compute should decrease by 15–25%
- [ ] `wrk`: median throughput for compute should improve by 3–6%
- [ ] `valgrind --tool=memcheck` → no memory errors

#### Realistic Expected Gain

- **Compute: +3–6%** (corrected from +10–15%)
- **Hello: +1–2%** (corrected from +3–5%)
- Highest single-fix ROI for compute scenario

---

### ~~2.2 SIMD validation loop~~ — **DEFERRED**

**Verdict: DEFER.** For typical headers (50–80 bytes), SIMD saves ~200–400 instructions — negligible. CRLF check cannot be SIMD-ified (cross-boundary dependency). Proposed SIMD code in original plan was **incomplete** — it omitted CRLF validation, creating a correctness bug. Only worthwhile for headers > 1KB (not the canonical workload).

**When to revisit:** Only after confirming headers > 1KB in production workloads.

---

### Phase 2 Summary (Updated)

| Fix | File | Effort | Realistic Gain | Confidence |
|---|---|---|---|---|
| Skip body validation | `http.cpp:627-642` | 30 min | +3–6% compute, +1–2% hello | **Medium-High** |

**Corrected from original:** +10–15% compute → +3–6% compute. SIMD validation moved to DEFER.

---

## Updated Phase 3: Routing & Dispatch Optimization — 1 hour, Requires Verification

### Цель
Optimize routing and dispatch overhead.

**Corrected from original Phase 3 (serialization) and Phase 4 (routing):** Serialization work moved to DEFER. Routing work elevated.

---

### 3.1 Switch hello to `fast_router`

**Verdict: DO AFTER VERIFICATION.**

Compute already uses `fast_router`. Pattern is proven. Dispatch = 11.85% perf in hello. Direct match eliminates path splitting, segment matching, specificity scoring.

Follow compute_api's `fast_router` pattern:
```cpp
class hello_fast_router {
public:
    katana::result<void> dispatch_to(const katana::http::request& req,
                                     katana::http::request_context& ctx,
                                     katana::http::response& out) const {
        if (req.http_method == katana::http::method::get && req.uri == "/") {
            out.reset();
            out.status = 200;
            out.reason.assign(katana::http::canonical_reason_phrase(200));
            out.body = "Hello, World!";
            out.set_header(katana::http::field::content_type, "text/plain");
            return {};
        }
        return std::unexpected(katana::make_error_code(katana::error_code::not_found));
    }
};
```

**Realistic expected gain: +3–6% hello** (corrected from +8–12%). Gain limited by Amdahl's Law — dispatch is not the only cost.

**Validation:**
- wrk: hello throughput should improve
- curl: identical response
- callgrind: dispatch Ir should decrease significantly

---

### 3.2 Fix string lookups in generated dispatch code

**Verdict: DO AFTER VERIFICATION.**

**File:** `compute_api/generated/generated_router_bindings.hpp` — lines 64–104

**Changes:**

```diff
 // Line ~101: string-based set_header → enum-based
-        out.set_header("Content-Type", kJsonContentType);
+        out.set_header(katana::http::field::content_type, kJsonContentType);

 // Line ~99: get → contains for Content-Type check
-    if (out.status != 204 && !out.body.empty() &&
-        !out.headers.get(katana::http::field::content_type)) {
+    if (out.status != 204 && !out.body.empty() &&
+        !out.headers.contains(katana::http::field::content_type)) {
```

**Realistic expected gain: +1–2% compute** (corrected from +3–5%). Main value: eliminate `string_to_field` calls in generated code.

**Validation:**
- E2E test: POST /compute/sum → 200 with correct Content-Type
- callgrind: `dispatch_compute_sum` Ir should decrease

---

### Phase 3 Summary (Updated)

| Fix | File | Effort | Realistic Gain | Confidence |
|---|---|---|---|---|
| Hello fast_router | hello server main | 30 min | +3–6% hello | **High** |
| Generated dispatch fix | `generated_router_bindings.hpp` | 30 min | +1–2% compute | **Medium** |

---

## Deferred / Dropped Items

### DROPPED (do not implement)

| # | Optimization | Original Estimate | Why Drop |
|---|---|---|---|
| 1.3 | `[[gnu::always_inline]]` on `skip_ws()` | +1% | Effect < 0.01%. Call/ret overhead for 164K calls ≈ 0.5–0.8M cycles out of billions. Compiler likely already inlines at -O2/-O3. ~100x overestimate. |
| 5.4 | Custom JSON parser for compute | +3x micro | JSON parsing = 3–5% Ir total. Custom parser saves ~1% wallclock. Cost: duplicated logic, maintenance burden, correctness risk. ROI negative. |
| — | Fuse read+parse+dispatch | +0.5% | Destroys modularity for negligible function call overhead savings. |

### DEFERRED (do after measuring Phases 1–3)

| # | Optimization | Original Estimate | Corrected | Why Defer | When to Revisit |
|---|---|---|---|---|---|
| 3.1 (old) | Single-pass serialize | +5–8% hello | +1–3% | perf% shows serialize is only 9.36% wallclock (not 29.22% Ir). "Single-pass" proposal is still two-pass with better reserve. ROI doesn't justify. | After Phases 1–3 if serialize still top-3 bottleneck. |
| 3.2 (old) | io_buffer serialize path | +8–12% hello | +2–5% | Exists in code but unused on hot path — suspicious. May have bugs. Also has `get("Content-Length")` string lookup bug. | After investigating why it's unused. Run memcheck first. |
| 2.2 | SIMD parser validation | +5–10% hello | <1% typical | Headers 50–80 bytes: SIMD saves ~200–400 instructions. CRLF check can't be SIMD-ified. Proposed code incomplete. | Only after confirming headers > 1KB in production. |
| 3.3 (old) | Pre-built response template | +15–25% hello | Significant but fragile | Breaks on Connection: close, middleware headers, non-200 status. Not suitable for general-purpose framework. | Only if hello throughput is specific business requirement. |
| 5.3 | Compile-time route table | +3–5% | Marginal | `fast_router` already O(1) dispatch. Marginal over runtime hash. | Only if profiling shows `fast_router` as top-5 bottleneck. |
| 5.2 | Zero-copy response (writev) | Unknown | Unknown | Cannot measure in VirtualBox. VM exit/enter overhead may dominate. | Only on bare-metal with PMU-enabled profiling. |

---

## Updated First Patch Set

Only changes with verdict DO NOW — implement immediately, zero risk.

### Patch 1: Field enum lookups in serialize_into

**File:** `http.cpp`, function `response::serialize_into(std::string&)`, line 214

```diff
-    bool has_content_length = headers.get("Content-Length").has_value();
+    bool has_content_length = headers.contains(field::content_length);
```

**File:** `http.cpp`, function `response::serialize_head_into(std::string&)`, line 278

```diff
-    bool has_content_length = headers.get("Content-Length").has_value();
+    bool has_content_length = headers.contains(field::content_length);
```

**Validation:**
- `callgrind_annotate | grep string_to_field` — Ir count should decrease by ≥15%
- `curl http://127.0.0.1:8080/` — response must be identical byte-for-byte

### Patch 2: Field enum lookups in handle_connection

**File:** `http_server.cpp`, function `handle_connection(...)`, lines 418–422

```diff
-        auto connection_header = req.headers.get("Connection");
+        auto connection_header = req.headers.get(http::field::connection);
         bool close_connection =
             connection_header && (*connection_header == "close" || *connection_header == "Close");

-        if (!resp.headers.get("Connection")) {
+        if (!resp.headers.contains(http::field::connection)) {
```

**Validation:**
- Send request with `Connection: close` → server must close connection
- Send request with `Connection: keep-alive` → server must keep connection alive
- Send request without Connection header → default behavior

### Patch 3: Branchless ci_char_equal

**File:** `http_headers.hpp`, function `ci_char_equal(char, char)`, lines 31–34

```diff
 inline bool ci_char_equal(char a, char b) noexcept {
-    return std::tolower(static_cast<unsigned char>(a)) ==
-           std::tolower(static_cast<unsigned char>(b));
+    if (a == b) return true;
+    unsigned char ua = static_cast<unsigned char>(a);
+    unsigned char ub = static_cast<unsigned char>(b);
+    return (ua ^ ub) == 0x20 && ((ua | 0x20) >= 'a') && ((ua | 0x20) <= 'z');
 }
```

**Validation:**
- `ci_char_equal('A', 'a')` → true
- `ci_char_equal('Z', 'z')` → true
- `ci_char_equal('^', '~')` → false (would be true with naive `|0x20`)
- `ci_char_equal('@', '`')` → false
- `ci_char_equal('0', '0')` → true
- `ci_char_equal('-', '-')` → true
- `perf report` — `tolower` should disappear from compute top symbols

### Patch 4: Optimize prepare_for_next_request

**File:** `http.cpp`, function `parser::prepare_for_next_request()`, line ~1152

```diff
 void parser::prepare_for_next_request(monotonic_arena* arena) noexcept {
     size_t remaining = buffered_bytes();
-    if (remaining > 0 && parse_pos_ > 0) {
+    if (remaining == 0) {
+        buffer_size_ = 0;
+    } else if (parse_pos_ > 0) {
         std::memmove(buffer_, buffer_ + parse_pos_, remaining);
+        buffer_size_ = remaining;
     }
-    buffer_size_ = remaining;
     reset_message_state(arena);
 }
```

**Validation:**
- wrk with pipelining — no regression
- `valgrind --tool=memcheck` — no memory errors

### Patch 5: Skip body byte validation (DO AFTER VERIFICATION)

See **Parser Fix Design** section above for complete implementation details, including:
- Exact code changes (Patches A, B, C)
- Edge case analysis table
- Validation checklist

This patch should be implemented after Patches 1–4 are validated.

---

## Final Rollout Order (Updated)

```
┌──────────────────────────────────────────────────────────────┐
│                   Step 1: Quick Wins (30 min)                │
│                   Zero risk, +2–4% both                      │
├──────────────────────────────────────────────────────────────┤
│  Patch 1: field enum lookups (serialize)      5 min          │
│  Patch 2: field enum lookups (handle_conn)    5 min          │
│  Patch 3: branchless ci_char_equal            5 min          │
│  Patch 4: prepare_for_next memmove skip       5 min          │
│                                                              │
│  → Verify: wrk × 5 median + callgrind comparison            │
├──────────────────────────────────────────────────────────────┤
│                Step 2: Parser Fix (30 min)                    │
│                +3–6% compute, +1–2% hello                    │
├──────────────────────────────────────────────────────────────┤
│  Patch 5: Skip body byte validation                          │
│                                                              │
│  → Verify: UTF-8 body test, wrk, callgrind                   │
├──────────────────────────────────────────────────────────────┤
│              Step 3: Routing/Dispatch (1 hr)                 │
│              +3–6% hello, +1–2% compute                      │
├──────────────────────────────────────────────────────────────┤
│  Switch hello to fast_router                  30 min         │
│  Fix string lookups in generated dispatch     30 min         │
│                                                              │
│  → Verify: wrk + callgrind                                   │
├──────────────────────────────────────────────────────────────┤
│              Step 4: Validate and Iterate                     │
├──────────────────────────────────────────────────────────────┤
│  Measure combined gains                                      │
│  Re-profile to identify new top bottlenecks                  │
│  Decide whether to pursue deferred items                     │
└──────────────────────────────────────────────────────────────┘
```

---

## Final Expected Outcome (Updated)

### What is likely (>70% confidence)

After Steps 1–3:

- **Compute throughput: +4–8%**
  - From: field enum (+1.5%), tolower fix (+1.5%), body validation skip (+3–4%), dispatch string fix (+0.5%)
  - Multiplicative: 1.015 × 1.015 × 1.035 × 1.005 ≈ 1.07 → ~+7%

- **Hello throughput: +4–7%**
  - From: field enum (+1.5%), fast_router (+4%), prepare_for_next (+0.3%)
  - Multiplicative: 1.015 × 1.04 × 1.003 ≈ 1.06 → ~+6%

- **Latency (p99): 5–10% improvement** (proportional to throughput gain under load)
- **One latent bug fixed:** UTF-8 body bytes no longer incorrectly rejected

### What is optimistic but still plausible (30–50% confidence)

- **Compute: +10–15%** — if body validation skip saves more than estimated, or I/O bound fraction is small (<30%)
- **Hello: +8–12%** — if fast_router eliminates more overhead than estimated

### What is unlikely (<20% confidence)

- **+20–35%** (original plan's claim) — requires all optimizations at optimistic estimates, additive gains, fully CPU-bound, no VirtualBox overhead
- **SIMD parser providing measurable E2E gain** for canonical workloads (headers too short)

### Summary of Corrections from Original Plan

| Metric | Original Claim | Corrected Estimate | Factor |
|---|---|---|---|
| Day 1 quick wins | +5–8% both | +2–4% both | ~2x |
| Body validation skip (compute) | +10–15% | +3–6% | ~2.5x |
| Top-5 combined (compute) | +20–30% | +6–12% | ~2.5x |
| Top-5 combined (hello) | +15–25% | +5–10% | ~2.5x |
| always_inline skip_ws | +1% | <0.01% | ~100x |
| Single-pass serialize (hello) | +5–8% | +1–3% | ~3x |

**Root cause of overestimates:**
1. Using Ir% as direct proxy for throughput% (1.5–3x inflation)
2. Additive stacking of gains (violates Amdahl's Law)
3. Not accounting for I/O bound ceiling
4. Not accounting for VirtualBox noise floor (~3%)

---

*This updated plan reflects the final adjudicator verdict. Implement Steps 1–3, measure, then reassess before pursuing deferred items.*
