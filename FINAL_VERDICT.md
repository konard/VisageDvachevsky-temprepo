# Final Technical Adjudicator Verdict: KATANA Optimization Plan

Based on: PERFORMANCE_REVIEW.md (original plan), IMPLEMENTATION_PLAN.md (detailed execution), CRITICAL_REVIEW.md (critique).

This document does not introduce new analysis. It consolidates existing evidence, corrects inflated estimates, and delivers a final engineering decision.

---

## Раздел 1. Final Verdict Table

For each proposed optimization, a verdict is given based on evidence strength, realistic gain (corrected for Ir%→wallclock ratio and Amdahl's Law), risk, and effort.

**Key correction applied throughout:** Ir% ≠ wallclock%. Evidence from the profiling data itself shows the ratio:

| Function | perf% (wallclock) | Ir% (callgrind) | Ratio |
|---|---|---|---|
| `parse_available()` (compute) | 31.67% | 48.03% | 0.66x |
| `serialize_into()` (hello) | 9.36% | 29.22% | 0.32x |
| `dispatch_with_info()` (hello) | 11.85% | 15.97% | 0.74x |

All throughput estimates below use perf% as the primary basis, not Ir%.

### Verdict Table

| # | Optimization | Verdict | Realistic Gain | Confidence | Risk | Effort | Comment |
|---|---|---|---|---|---|---|---|
| 1 | Replace string-based header lookups with `field` enum (`http.cpp:214,278`, `http_server.cpp:418,422`) | **DO NOW** | +1.5–2.5% both | High | Zero | 5 min | API already exists. Eliminates `string_to_field` hash+scan on 4 hot-path calls. Not all 7.41% Ir comes from these 4 calls (parser also calls `string_to_field`), so real saving is a fraction. |
| 2 | Replace `std::tolower` with branchless ASCII lowering in `ci_char_equal` (`http_headers.hpp:31-34`) | **DO NOW** | +1–2% compute, +0.5% hello | High | Minimal | 5 min | Must use XOR+range check variant (not simple `\|0x20`) to avoid `^`==`~` false positive. Note: `ci_equal_short` and SIMD paths already use `\|0x20` — that pre-existing inconsistency is out of scope for this fix but should be tracked. `ci_hash` still uses `tolower` — acceptable since hash collisions are handled by equality comparison. |
| 3 | Skip body byte validation in parser (`http.cpp:627-642`) | **DO AFTER VERIFICATION** | +3–6% compute, +1–2% hello | Medium-High | Low-Medium | 30 min | Highest single-fix ROI for compute. But: (a) must NOT use `find_header_terminator()` per call — it's O(N) scan that may negate savings. Correct approach: set `validated_bytes_ = buffer_size_` when parser transitions from `headers` to `body` state, so subsequent `parse_available()` calls skip validation entirely. (b) Body bytes ~29% of total request for canonical compute payload, not 50%+. (c) Ir%→wallclock correction: 22% Ir × 29% body fraction × 0.66 ratio ≈ 4.2%. (d) Also fixes a latent bug: current code rejects UTF-8 body bytes (>= 0x80), violating RFC 7230 §3.3. (e) Null bytes in body will pass through — acceptable for JSON endpoints (JSON parser rejects them), but downstream handlers using C-strings should be audited. |
| 4 | Switch hello server to `fast_router` | **DO AFTER VERIFICATION** | +3–6% hello | High | Zero | 30 min | Compute already uses `fast_router`. Pattern is proven. Dispatch = 11.85% perf in hello. Direct match eliminates path splitting, segment matching, specificity scoring. Gain limited by Amdahl's Law — dispatch is not the only cost. |
| 5 | `[[gnu::always_inline]]` on `skip_ws()` (`serde.hpp:70`) | **DROP** | <0.01% | Very Low | Zero | 1 min | Critical review demonstrates this is unmeasurable. Call/ret overhead for 164K calls ≈ 0.5–0.8M cycles out of billions. Compiler likely already inlines it at -O2/-O3. Check with `objdump` before wasting time. |
| 6 | Single-pass serialize with exact reserve (`http.cpp:203-268`) | **DEFER** | +1–3% hello | Medium | Low | 1 hr | Critical review correctly identifies that proposed "single-pass" code is still two-pass — only difference is more accurate `reserve`. Current `reserve` already allocates adequately. perf% for `serialize_into` is only 9.36% (not 29.22% Ir), meaning serialize instructions are cheap (cache-friendly memcpy/append with high IPC). ROI doesn't justify effort vs. other fixes. |
| 7 | Switch hot path to `io_buffer` serialize (`http_server.cpp:440`) | **DEFER** | +2–5% both | Medium | Medium | 2 hrs | `io_buffer` overload exists but is unused on hot path — investigate why before adopting. May have undiscovered bugs or API incompatibility with pipelining. The io_buffer overload also uses `headers.get("Content-Length")` string lookup (same bug as #1). Needs testing under `valgrind --tool=memcheck`. |
| 8 | SIMD validation loop (SSE2/AVX2) (`http.cpp:632-640`) | **DEFER** | <1% for typical payloads | Low | Medium | 3 hrs | For hello (headers ≈ 50-80 bytes): 3-5 SIMD iterations save ~200-400 instructions out of 51.6M — negligible. CRLF check cannot be SIMD-ified (cross-boundary dependency). Proposed SIMD code in implementation plan is **incomplete** — it omits CRLF validation, creating a correctness bug. Only worthwhile for very large headers (>1KB), which is not the canonical workload. |
| 9 | Pre-built response template for hello (`http.cpp` + hello server) | **DEFER** | Significant for hello, but fragile | Medium | Medium | 3-4 hrs | Works only for static response shapes. Connection header varies (keep-alive vs close). Middleware may add dynamic headers. Any endpoint extension breaks template. Maintenance cost exceeds benefit for a general-purpose framework. |
| 10 | Optimize generated dispatch — Accept/Content-Type checks (`generated_router_bindings.hpp:64-104`) | **DO AFTER VERIFICATION** | +1–2% compute | Medium | Low | 30 min | Main value: replace `out.set_header("Content-Type", ...)` with `out.set_header(field::content_type, ...)` (same pattern as #1). The `[[unlikely]]` hint on Accept check is semantically neutral — minor branch prediction benefit at best. Real savings come from eliminating string lookups in generated code. |
| 11 | Custom JSON parser for compute (`serde.hpp`) | **DROP** | ~1% throughput | Low | Medium | 2 hrs | JSON parsing ≈ 3–5% Ir total. Custom parser saves maybe half → 1.5–2.5% Ir → ~1% wallclock. Cost: duplicated parsing logic, maintenance burden, correctness risk. ROI does not justify. |
| 12 | Optimize `prepare_for_next_request` memmove (`http.cpp:1152`) | **DO NOW** | +0.3–0.5% both | High | Zero | 5 min | Skip `memmove` when `parse_pos_ >= buffer_size_` (all data consumed). Trivial, zero-risk. Marginal gain but free. |
| 13 | Compile-time route table with constexpr hashing (`router.hpp`) | **DEFER** | Significant but architectural | Medium | Medium-High | 4-6 hrs | Architectural change. `fast_router` already provides O(1) runtime hash dispatch. Marginal improvement over fast_router doesn't justify redesign. |
| 14 | Zero-copy response path with writev (`http.cpp`, `http_server.cpp`) | **DEFER** | Unknown | Low | High | 4-8 hrs | Cannot reliably measure in VirtualBox. VM exit/enter overhead may dominate I/O syscalls. Needs bare-metal validation first. |
| 15 | Fuse read+parse+dispatch into single function | **DROP** | ~0.5% | Very Low | High | 4+ hrs | Destroys modularity for negligible function call overhead savings. |

---

## Раздел 2. Final Execution Order

Only items with verdict DO NOW or DO AFTER VERIFICATION, ordered by ROI × confidence.

### Step 1: Quick Wins (30 minutes total, zero risk)

**Expected combined gain: +2–4% both scenarios.**

These three changes are independent, can be done in parallel, and have zero risk of regression.

1. **Replace string-based header lookups with `field` enum** (verdict: DO NOW)
   - `http.cpp:214` — `headers.get("Content-Length")` → `headers.contains(field::content_length)`
   - `http.cpp:278` — same change in `serialize_head_into`
   - `http_server.cpp:418` — `req.headers.get("Connection")` → `req.headers.get(http::field::connection)`
   - `http_server.cpp:422` — `resp.headers.get("Connection")` → `resp.headers.contains(http::field::connection)`

2. **Replace `ci_char_equal` tolower with branchless ASCII lowering** (verdict: DO NOW)
   - `http_headers.hpp:31-34` — use XOR+range check variant:
     ```cpp
     if (a == b) return true;
     unsigned char ua = static_cast<unsigned char>(a);
     unsigned char ub = static_cast<unsigned char>(b);
     return (ua ^ ub) == 0x20 && ((ua | 0x20) >= 'a') && ((ua | 0x20) <= 'z');
     ```

3. **Optimize `prepare_for_next_request`** (verdict: DO NOW)
   - `http.cpp:1152` — skip `memmove` when all data consumed (`remaining == 0`)

### Step 2: Parser Body Validation Fix (30 minutes, requires verification)

**Expected gain: +3–6% compute, +1–2% hello.**

4. **Skip body byte validation** (verdict: DO AFTER VERIFICATION)
   - `http.cpp:627-642`
   - **Correct approach**: When parser transitions from state `headers` to state `body` (line ~763 where `return state::body`), the validation loop already won't run on subsequent `parse_available()` calls (guarded by `state_ == request_line || state_ == headers`). The issue is the **first** call where one `read()` delivers both headers and body bytes.
   - **Implementation**: Limit `validation_limit` to header-end position. Since the parser already tracks where headers end during parsing, cache that position instead of calling `find_header_terminator()` (which is O(N) and would negate savings).
   - **Verification required**: (a) Unit test with UTF-8 body (currently incorrectly rejected), (b) Unit test with null bytes in body, (c) callgrind Ir comparison for `parse_available`.

### Step 3: Routing & Dispatch Optimization (1 hour, requires verification)

**Expected gain: +3–6% hello, +1–2% compute.**

5. **Switch hello to `fast_router`** (verdict: DO AFTER VERIFICATION)
   - Follow compute_api's `fast_router` pattern. Direct method+path match without path splitting or segment matching.

6. **Fix string lookups in generated dispatch** (verdict: DO AFTER VERIFICATION)
   - `generated_router_bindings.hpp:101` — `out.set_header("Content-Type", ...)` → `out.set_header(field::content_type, ...)`
   - `generated_router_bindings.hpp:99` — `out.headers.get(field::content_type)` → `out.headers.contains(field::content_type)`

### Step 4: Validate and Iterate

After Steps 1–3, measure:
- `wrk -t4 -c512 -d10s` × 5 runs, take median throughput
- `callgrind` reduced pass for affected functions
- Compare against baseline

**Expected combined realistic gain after Steps 1–3: +6–12% compute, +5–10% hello.**

This is substantially lower than the original plan's claim of +20–35%, because:
- Ir% ≠ wallclock% (systematic 1.5–3x overestimate corrected)
- Gains are not additive (Amdahl's Law applied)
- I/O bound fraction unknown (sets a ceiling on CPU optimization gains)
- VirtualBox adds unmeasured overhead

If measured gains are lower than expected, investigate I/O bound vs CPU bound ratio before pursuing further optimizations.

---

## Раздел 3. First Patch Set

The first 3–5 changes to implement immediately. Each includes exact files, functions, code changes, and validation steps.

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
- Send request without Connection header → server must apply default behavior

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
- wrk with pipelining — no regression in throughput
- `valgrind --tool=memcheck` — no memory errors
- callgrind: `prepare_for_next_request` Ir should decrease slightly

### Patch 5: Skip body byte validation (requires verification first)

**File:** `http.cpp`, function `parser::parse_available()`, lines 627–642

**Approach:** Track the end-of-headers position in the parser state. When the header terminator (`\r\n\r\n`) is found during normal parsing (which already happens), save that position. Use it to limit the validation loop.

```diff
+    // Member variable added to parser class:
+    // size_t header_end_pos_ = 0;  // position after \r\n\r\n, 0 = not yet found

     if (state_ == state::request_line || state_ == state::headers) [[likely]] {
         size_t validation_start = validated_bytes_;
         if (validation_start > 0) {
             --validation_start;
         }
-        for (size_t i = validation_start; i < buffer_size_; ++i) {
+        // Limit validation to header bytes only. Body bytes don't need
+        // HTTP header validation and may contain valid UTF-8 (>= 0x80).
+        size_t validation_limit = (header_end_pos_ > 0 && header_end_pos_ < buffer_size_)
+                                  ? header_end_pos_
+                                  : buffer_size_;
+        for (size_t i = validation_start; i < validation_limit; ++i) {
             uint8_t byte = static_cast<uint8_t>(buffer_[i]);
             if (byte == 0 || byte >= 0x80) [[unlikely]] { ... }
             if (byte == '\n' && (i == 0 || buffer_[i - 1] != '\r')) [[unlikely]] { ... }
         }
         validated_bytes_ = buffer_size_;
     }
```

And where headers end is detected (existing code that finds `\r\n\r\n`):
```diff
+    header_end_pos_ = /* position after the \r\n\r\n terminator */;
```

**Validation:**
- POST with UTF-8 JSON body → must succeed (fixes latent bug where >= 0x80 bytes were rejected)
- POST with null byte in body → JSON parser should reject, but parser should not
- callgrind: `parse_available` Ir in compute should decrease by 15–25%
- wrk: median throughput for compute should improve by 3–6%

---

## Раздел 4. Things to Drop or Defer

### DROP (do not implement)

| # | Optimization | Why Drop |
|---|---|---|
| 5 | `[[gnu::always_inline]]` on `skip_ws()` | Effect is < 0.01% — unmeasurable noise. Call/ret overhead for 164K calls ≈ 0.5–0.8M cycles out of billions. Compiler likely already inlines at -O2/-O3. Verify with `objdump -d` — if `skip_ws` doesn't appear as a separate symbol, it's already inlined. |
| 11 | Custom JSON parser for compute | JSON parsing = 3–5% Ir total. Custom parser saves ~1% wallclock at best. Cost: duplicated logic, maintenance burden, edge case handling (whitespace, errors, empty arrays). ROI is negative when accounting for engineering time. |
| 15 | Fuse read+parse+dispatch | Destroys modularity for ~0.5% gain from eliminated function call overhead. Architecturally harmful. |

### DEFER (do later, after measuring Steps 1–3)

| # | Optimization | Why Defer | When to Revisit |
|---|---|---|---|
| 6 | Single-pass serialize | perf% shows serialize is only 9.36% wallclock (not 29.22% Ir). "Single-pass" proposal is actually still two-pass with better reserve. ROI is +1–3% at best. | After Steps 1–3 if serialize is still a top-3 bottleneck in updated profile. |
| 7 | io_buffer serialize path | Exists in code but unused on hot path — suspicious. May have bugs or API incompatibilities. Also has the same `headers.get("Content-Length")` string lookup bug. | After investigating why it's unused. Run through memcheck first. |
| 8 | SIMD parser validation | For typical headers (50–80 bytes), SIMD saves ~200–400 instructions — negligible. CRLF check can't be SIMD-ified. Proposed code is incomplete (missing CRLF validation). | Only after confirming headers > 1KB in production workloads. |
| 9 | Pre-built response template | Fragile: breaks on Connection: close, middleware headers, non-200 status. Limited to one endpoint shape. | Only if hello throughput is a specific business requirement and framework is not expected to be general-purpose. |
| 13 | Compile-time route table | `fast_router` already provides O(1) dispatch. Marginal improvement over runtime hash. | Only if profiling shows `fast_router` dispatch as a top-5 bottleneck. |
| 14 | Zero-copy response (writev) | Cannot measure in VirtualBox. VM exit/enter overhead may dominate syscall cost. | Only on bare-metal with PMU-enabled profiling. |

### Key reasons for conservative deferrals:

1. **I/O bound ceiling unknown.** No analysis exists for I/O vs CPU bound ratio. If syscall overhead (epoll_wait + read + write) is 40–60% of request lifecycle, then all CPU optimizations combined have a ceiling of 40–60% maximum improvement × fraction of CPU time affected.

2. **VirtualBox measurement noise.** wrk throughput variance in VM can be 10–20%. Changes below 3% throughput improvement are within noise and cannot be reliably validated.

3. **Amdahl's Law.** Even if parser is 32% of wallclock (perf%), optimizing it by 30% gives 1/(1 - 0.32×0.30) - 1 ≈ 10.6% improvement — not 30%.

---

## Раздел 5. Final Expected Outcome

### What is likely (>70% confidence)

After implementing Steps 1–3 (DO NOW + DO AFTER VERIFICATION items):

- **Compute throughput: +4–8%**
  - From: field enum lookups (+1.5%), tolower fix (+1.5%), body validation skip (+3–4%), dispatch string fix (+0.5%)
  - These are multiplicative, not additive: 1.015 × 1.015 × 1.035 × 1.005 ≈ 1.07 → ~+7%

- **Hello throughput: +4–7%**
  - From: field enum lookups (+1.5%), fast_router (+4%), prepare_for_next fix (+0.3%)
  - Multiplicative: 1.015 × 1.04 × 1.003 ≈ 1.06 → ~+6%

- **Latency (p99): 5–10% improvement** in both scenarios (proportional to throughput gain under load)

- **No correctness regressions** for field enum lookups, tolower fix, prepare_for_next_request optimization

- **One latent bug fixed**: UTF-8 body bytes no longer incorrectly rejected (body validation skip)

### What is optimistic but still plausible (30–50% confidence)

- **Compute throughput: +10–15%**
  - If body validation skip saves more than estimated (larger body payloads, or validation loop IPC is lower than average — meaning Ir%→wallclock ratio is closer to 1.0 for this specific loop)
  - If I/O bound fraction is small (<30%), giving more headroom for CPU optimizations

- **Hello throughput: +8–12%**
  - If fast_router eliminates more overhead than estimated (dispatch_with_info has complex control flow that pollutes branch predictor, and elimination improves IPC for surrounding code)
  - If subsequent profiling reveals additional quick wins from updated bottleneck ranking

- **Additional gains from deferred items**: After measuring Steps 1–3, the updated profile may reveal that serialize or io_buffer optimizations have better ROI than currently estimated, enabling a second round of +3–5% gains.

### What is unlikely (<20% confidence)

- **+20–35% throughput** (original plan's claim)
  - Requires all optimizations to achieve their optimistic estimates simultaneously
  - Requires gains to be additive (they're not — Amdahl's Law)
  - Requires workload to be fully CPU-bound (no I/O ceiling)
  - Requires VirtualBox overhead to not mask gains

- **SIMD parser providing measurable E2E gain** for canonical workloads
  - Headers are too short (50–80 bytes) for SIMD to amortize setup cost
  - CRLF validation cannot be SIMD-ified, requiring hybrid approach

- **Static response template being production-viable** without fragility
  - Any middleware, error handling, or Connection header variation breaks the template
  - Not suitable for a general-purpose framework

### Summary of corrections from original plan

| Metric | Original Plan Claim | Corrected Estimate | Correction Factor |
|---|---|---|---|
| Day 1 quick wins | +5–8% both | +2–4% both | ~2x overestimate |
| Body validation skip (compute) | +10–15% | +3–6% | ~2.5x overestimate |
| Top-5 combined (compute) | +20–30% | +6–12% | ~2.5x overestimate |
| Top-5 combined (hello) | +15–25% | +5–10% | ~2.5x overestimate |
| always_inline skip_ws | +1% | <0.01% | ~100x overestimate |
| Single-pass serialize (hello) | +5–8% | +1–3% | ~3x overestimate |

**Root cause of overestimates:**
1. Using Ir% as direct proxy for throughput% (demonstrated 1.5–3x inflation via perf/callgrind ratio)
2. Additive stacking of individual gains (violates Amdahl's Law)
3. Not accounting for I/O bound ceiling
4. Not accounting for VirtualBox measurement noise floor (~3%)

---

*This verdict is final. Implement Steps 1–3, measure, then reassess before pursuing deferred items.*
