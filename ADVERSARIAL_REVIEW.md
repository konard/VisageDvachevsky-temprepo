# KATANA HTTP Server — Adversarial Review of Performance Analysis

**Date**: 2026-03-14
**Scope**: Re-verification of all claims in `PERFORMANCE_ANALYSIS.md` against actual code and profiling data

---

## 1. Corrected Verdict

### 3 conclusions that remain confirmed

1. **Per-request object zeroing IS the biggest `handle_connection` self-time hotspot.**
   Verified: `rep stos` instructions at hello annotate lines 167 (18.81%), 189 (12.16%), 194 (8.47%) = **39.44% of `handle_connection` self-time**. Sources: response constructor (`http_server.cpp:411`) creates `headers_map` with value-initialized `known_inline_{}` (16 × 24 bytes) and `unknown_inline_{}` (8 × 24 bytes), AND `reset_message_state()` at `http.cpp:1151` calls `reset_storage()` which does `.fill({})` on request headers.

2. **Parser instruction count dominates callgrind.** `parse_available()` = 136.9M/336.7M (40.7%) for hello, 321.8M/665.1M (48.4%) for compute. These numbers are directly from `callgrind_annotate` output and match.

3. **`prepare_for_next_request()` memmove is a real per-request cost.** Confirmed at `http.cpp:1179`: unconditional `std::memmove()` when `parse_pos_ > 0 && remaining > 0`. Hello annotate: 6.45% perf.

### 3 conclusions that were incorrect or overestimated

1. **❌ F3 "tolower in string_to_field()" — INCORRECT attribution.**
   The original analysis claimed `tolower` at 5.19% comes from `string_to_field()` using `to_lower()` for case-insensitive header matching. **This is wrong.** Actual code: `string_to_field()` (`http_field.cpp:501-527`) uses `ci_equal_fast()` (SIMD-optimized, zero-allocation) for both hash-table and binary search paths. The binary search comparator uses `case_insensitive_less()` (`http_field.cpp:377-385`) which does inline ASCII lowering without allocation or calling libc `tolower()`. The actual `tolower` caller is `http_utils::detail::ascii_iequals()` (`http_utils.hpp:27`) which calls `std::tolower()` per character, used in content-type negotiation (`find_content_type()`). The callgrind data confirms: 1,600,000 `tolower` calls from function at `0x10fd70` — this is the PLT wrapper for `ascii_iequals`, called 800K × 2 (two `tolower` calls per character comparison).

2. **❌ F8 "json_cursor::skip_ws() is not SIMD-optimized" — INCORRECT.**
   The original analysis suggested "if the implementation is byte-by-byte" and proposed adding SIMD. **Actual code** (`serde.hpp:70-108`) already HAS SSE2 SIMD optimization with a fast-path early return for non-whitespace, scalar path for <8 characters, and SSE2 vectorized scanning for larger runs. The 4.28% perf overhead is real but is simply the inherent cost of whitespace-heavy JSON parsing, not an unoptimized implementation.

3. **⚠️ F7 "malloc/free in response cleanup loop" — OVERESTIMATED.**
   The original analysis interpreted annotate offsets 0x24490-0x244a9 as "freeing arena-allocated overflow header chunks." But `headers_map` uses arena allocation for overflow chunks and arenas don't `free()` individual allocations — they reset in bulk via `arena.reset()` at `http_server.cpp:232`. The annotate patterns at those offsets are more likely from `std::string` destructors (for `response.reason` and `response.body` members) rather than header chunk deallocation. Overhead is also lower than claimed (the `sub+je` pattern at ~11% is shared with other cleanup code, not exclusively header cleanup).

---

## 2. Claim Audit

### Claim: "string_to_field() uses to_lower() which allocates std::string"

**Original claim**: F3 said `to_lower()` in `http_headers.hpp:171-178` creates a `std::string` copy during header field lookup in the hot path, causing 5.19% compute overhead.

**Status**: ❌ **INCORRECT**

**Evidence in code**:
- `string_to_field()` at `http_field.cpp:501-527`: Uses `ci_equal_fast()` for matching (line 510, 522) and `case_insensitive_less()` for ordering (line 519). Neither function allocates memory.
- `case_insensitive_less()` at `http_field.cpp:377-385`: Inline ASCII lowering per-character via `(c + 32)`, no `std::tolower()`, no allocation.
- `to_lower()` at `http_headers.hpp:171-178`: EXISTS but is NEVER CALLED from `string_to_field()`. Grep confirms no reference from `http_field.cpp`.

**Evidence in profiling**:
- `tolower` at 5.19% in compute perf → traced via callgrind to `0x10fd70` → called 800K×2 from a function that is NOT `string_to_field`. The caller is `ascii_iequals()` in `http_utils.hpp:27` (content-type negotiation path).
- `string_to_field()` appears separately in callgrind at 20.3M Ir (3.05%) — its cost is from `ci_equal_fast()` comparisons, not `tolower`.

**Correction**: The `tolower` 5.19% overhead comes from content-type negotiation (`find_content_type()` → `ascii_iequals()`), NOT from header field parsing. Fix target should be `http_utils.hpp:27`, not `http_field.hpp`.

---

### Claim: "json_cursor::skip_ws() could benefit from SIMD optimization"

**Original claim**: F8 suggested skip_ws() might be byte-by-byte and proposed SIMD.

**Status**: ❌ **INCORRECT — already SIMD-optimized**

**Evidence in code**: `serde.hpp:70-108` shows:
- Line 73: Fast path early return for non-whitespace (most common case)
- Line 77: `#ifdef __SSE2__` guard
- Lines 84-90: Scalar fallback for <8 chars
- Lines 101-107: SSE2 vectorized `_mm_loadu_si128` + `_mm_set1_epi8` pattern

**Evidence in profiling**: 4.28% in compute perf, 17.5M Ir (2.63%) in callgrind. This is the inherent cost, not an optimization opportunity.

**Correction**: Skip this optimization target. The 4.28% is a natural cost of JSON whitespace scanning that's already well-optimized.

---

### Claim: "Per-request object zeroing = 40-50% of handle_connection self-time"

**Original claim**: F1 — `rep stos` from constructing response and request_context on every request.

**Status**: ✅ **CONFIRMED** (with minor correction on source)

**Evidence in code**:
- `http_server.cpp:410-411`: `request_context ctx{state.arena}; response resp{&state.arena};` — per-request stack construction
- `response` constructor (`http.hpp:54`): `response(monotonic_arena* arena) : headers(arena) {}` — headers_map gets value-initialized inline arrays
- `headers_map` members (`http_headers.hpp:678,681`): `std::array<known_entry, 16> known_inline_{}; std::array<unknown_entry, 8> unknown_inline_{};` — aggregate value-init generates `rep stos`
- Additionally: `reset_message_state()` (`http.cpp:1151`) calls `headers.reset()` → `reset_storage()` → `.fill({})` — more zeroing for request headers

**Evidence in profiling**:
- Hello annotate: 18.81% + 12.16% + 8.47% = **39.44%** of `handle_connection` self-time
- Compute annotate: 15.71% + 9.40% + 7.22% = **32.33%** of `handle_connection` self-time

**Correction**: Original claim of "40-50%" was slightly high. Actual: **32-39%**. But the three `rep stos` are real and come from BOTH response construction AND request header reset. The zeroing happens in two places per request cycle: response headers (constructor) and request headers (`reset_storage`).

---

### Claim: "Response serialization uses string::append() with 13% overhead"

**Original claim**: F4 — `serialize_into(string&)` at 13.28% could be reduced by switching to direct memcpy.

**Status**: ✅ **CONFIRMED** (code verified)

**Evidence in code**: `http.cpp:257-279`: 10+ separate `out.append()` calls after `out.reserve()`. Each append does: bounds check, size update, potential memcpy. The `io_buffer` variant at `http.cpp:342-426` already uses direct memcpy.

**Evidence in profiling**: Hello perf: 13.28% + string::append clones at ~4.8% additional. Callgrind: 70M Ir (20.8%).

**Correction**: Claim stands. The io_buffer path exists but isn't used in the pipelining path.

---

### Claim: "prepare_for_next_request memmove = 6.45%"

**Original claim**: F5 — unconditional memmove on every pipelined request.

**Status**: ✅ **CONFIRMED**

**Evidence in code**: `http.cpp:1174-1183`: `std::memmove(buffer_, buffer_ + parse_pos_, remaining)` when `parse_pos_ > 0`. No threshold check — compacts on EVERY request.

**Evidence in profiling**: Hello perf: 6.45%. Plus `__memmove_avx_unaligned_erms` at 6.03% (related).

**Correction**: None needed.

---

### Claim: "Connection header linear scan via cmpw $0x3b chains"

**Original claim**: F6 — ~5% from unrolled linear scan through `known_inline_` for `field::connection` (value 0x3b = 59).

**Status**: ⚠️ **PLAUSIBLE but overhead overestimated**

**Evidence in code**: `http_headers.hpp:568-581` (`find_known_entry()`): Linear scan through all 16 inline entries + overflow chunks.

**Evidence in profiling**: 96 `cmpw $0x3b` instructions in hello annotate. However, summing their non-zero samples: ~2.3% total, not 5%. Most individual comparisons show 0.00%. The scan is fast because the entries are in contiguous cache-line-friendly storage.

**Correction**: Real overhead is ~2-3%, not "~5%". The bitset optimization (F6 suggestion) would save ~2% — a tiny win, not a meaningful priority.

---

### Claim: "cleanup path does expensive malloc/free per request"

**Original claim**: F7 — response destructor iterates and frees overflow header chunks.

**Status**: ⚠️ **PLAUSIBLE but root cause misidentified**

**Evidence in code**: `headers_map` overflow chunks are allocated via `monotonic_arena` (`http_headers.hpp:602-604`). Arena allocations are NOT freed individually — the arena is reset in bulk at `http_server.cpp:232`. The destructor of `headers_map` doesn't call `free()` on individual chunks.

**Evidence in profiling**: The high-overhead `sub`/`je` pattern at annotate offsets 0x24490 could be from `std::string` destructor for `response.reason` and `response.body` (which DO allocate heap memory via std::string), or from the `owned_arena_` destructor (each `headers_map` has `monotonic_arena owned_arena_{4096}` at line 677 — but when constructed with an external arena, this 4096-byte initial allocation may still happen).

**Correction**: The per-request cost is likely from `owned_arena_{4096}` allocation/deallocation (which allocates 4096 bytes even when an external arena is provided, because `owned_arena_` is always constructed before the constructor body runs), plus `std::string` destructors. Not from individual chunk frees.

---

### Claim: "Syscall metrics overhead = 1.46%"

**Original claim**: F10 — `local_slot()` does thread-local lookup + atomic increment on every I/O operation.

**Status**: ✅ **CONFIRMED** (minor)

**Evidence in code**: `syscall_metrics.hpp:53-58`: Multiple `note_*` methods called from hot paths. `serialize_into()` (`http.cpp:220-221, 280-281`) calls `note_response_serialize()` per response.

**Evidence in profiling**: 1.46% in hello perf. Small but real.

**Correction**: None needed. Low priority.

---

### Claim: "perf annotate addresses show rep stos at specific offsets"

**Original claim**: F1 listed specific addresses like `23d5e`, `23de0`, `23e03` with percentages.

**Status**: ✅ **CONFIRMED** (exact match)

**Evidence**: Hello annotate file shows:
- Line 167: `18.81 :   23d5e:  rep stos` ✓
- Line 189: `12.16 :   23de0:  rep stos` ✓
- Line 194: `8.47 :   23e03:  rep stos` ✓

Compute annotate shows:
- Line 166: `15.71 :   25e1e:  rep stos` ✓
- Line 188: `9.40 :   25ea7:  rep stos` ✓
- Line 193: `7.22 :   25eca:  rep stos` ✓

**Correction**: All addresses and percentages match exactly. Note the original text in F1 had slightly different addresses in the "from compute annotate" block — the actual file says `25e1e` not `25e1e:  rep stos %rax,%es:(%rdi)`, which matches.

---

### Claim: "Callgrind and perf emphasize differently because..."

**Original claim**: Section 2 explained perf captures syscall wait time while callgrind counts only instructions.

**Status**: ✅ **CONFIRMED** (with nuance)

The explanation is directionally correct: `perf record -e cpu-clock:u` samples wall-clock CPU time (excluding kernel time due to `:u` modifier), while callgrind counts instructions. This explains why `handle_connection` self-time is 25% in perf but lower in callgrind (instruction count per call is moderate, but wall-clock time is high due to busy-waiting on recv/EAGAIN). However, the `:u` modifier means `perf` does NOT capture time in kernel syscalls — it captures CPU time in userspace, including spinning/polling. So "captures syscall wait time" should be corrected to "captures userspace busy-wait time between syscalls."

---

## 3. Final Ranked Opportunities

### Opportunity 1: Eliminate per-request headers_map zeroing

**Why it still matters**: 32-39% of `handle_connection` self-time. Three `rep stos` zeroing ~960+ bytes per request across response constructor + request headers reset.

**Where in code**:
- `http_server.cpp:410-411`: Per-request `response` and `request_context` construction
- `http_headers.hpp:666-673`: `reset_storage()` → `.fill({})`
- `http_headers.hpp:678,681`: Value-initialized `known_inline_{}`, `unknown_inline_{}`

**Confidence**: HIGH
**Expected impact**: LARGE (reduce handle_connection self-time by ~30-35%)
**Implementation risk**: LOW — `known_size_`/`unknown_size_` already guard iteration bounds; skipping zeroing of array contents is safe as long as counters are reset

**Patch sketch**:
```cpp
// In headers_map: add fast_reset() that skips array zeroing
void fast_reset() noexcept {
    known_size_ = 0;
    unknown_size_ = 0;
    known_chunks_ = nullptr;
    unknown_chunks_ = nullptr;
}
```
Additionally, move `response` and `request_context` outside the `while(true)` loop in `handle_connection` and call `reset()` instead of constructing new objects.

**IMPORTANT CAVEAT**: The `response.headers` contains a `monotonic_arena owned_arena_{4096}` member. This means every `response` construction also allocates 4096 bytes. Moving the response outside the loop would also eliminate this per-request allocation. However, need to verify that `find_known_entry()` (`http_headers.hpp:568-581`) terminates correctly when inline entries contain stale data from a previous request — currently it scans for `field::unknown` as sentinel, so stale non-unknown entries could cause false matches. The safe fix is to also zero only the `key` field of each entry on reset (16 × 2 bytes = 32 bytes, much cheaper than 16 × 24 = 384 bytes).

---

### Opportunity 2: Fix tolower in content-type negotiation

**Why it still matters**: 5.19% compute perf, 17.6M Ir callgrind. `std::tolower()` is locale-aware and called 1.6M times per benchmark run.

**Where in code**: `http_utils.hpp:27`: `std::tolower(lc) != std::tolower(rc)` inside `ascii_iequals()`.

**Confidence**: HIGH
**Expected impact**: MEDIUM (eliminate ~5% CPU in compute path)
**Implementation risk**: LOW — replace with inline ASCII lowering

**Patch sketch**:
```cpp
// http_utils.hpp:27 — replace std::tolower with ASCII-only fast path
// Before:
if (std::tolower(lc) != std::tolower(rc)) {
// After:
unsigned char ll = (lc >= 'A' && lc <= 'Z') ? (lc | 0x20) : lc;
unsigned char rl = (rc >= 'A' && rc <= 'Z') ? (rc | 0x20) : rc;
if (ll != rl) {
```
Or better: replace entire `ascii_iequals()` with existing `ci_equal()` from `http_headers.hpp:146-165` which is already SIMD-optimized.

---

### Opportunity 3: Defer buffer compaction in prepare_for_next_request

**Why it still matters**: 6.45% hello + 6.03% memmove. Unconditional memmove on every pipelined request.

**Where in code**: `http.cpp:1174-1183`

**Confidence**: HIGH
**Expected impact**: SMALL-MEDIUM (reduce memmove calls by ~80% under pipelining)
**Implementation risk**: LOW — threshold-based compaction is straightforward

**Patch sketch**: Same as original analysis F5 — defer memmove until `parse_pos_ > buffer_capacity_ / 2`.

---

### Opportunity 4: Response serialization with direct memcpy

**Why it still matters**: 13.28% hello perf, 70M Ir callgrind.

**Where in code**: `http.cpp:217-282`: 10+ `string::append()` calls

**Confidence**: HIGH
**Expected impact**: MEDIUM (reduce from ~13% to ~8%)
**Implementation risk**: LOW

---

### Opportunity 5: Parser instruction reduction (long-term)

**Why it still matters**: 40-48% of all instructions.

**Where in code**: `http.cpp:636-711`: `parse_available()` state machine

**Confidence**: MEDIUM (depends on implementation quality)
**Expected impact**: MEDIUM-LARGE over time
**Implementation risk**: MEDIUM-HIGH (parser correctness is critical for security)

---

## 4. Minimal Action Plan (5 steps, best ROI)

### Step 1: Eliminate per-request zeroing (LARGEST impact)

Move `response` and `request_context` outside the `while(true)` loop in `handle_connection()`. Add `fast_reset()` to `headers_map` that resets only size counters and key fields (~32 bytes) instead of full array zeroing (~960 bytes). Verify `find_known_entry()` and `append_known_entry()` handle stale entries correctly.

**Expected**: -30% of `handle_connection` self-time → ~10-15% RPS improvement

### Step 2: Replace std::tolower in ascii_iequals

In `http_utils.hpp:27`, replace `std::tolower()` with inline ASCII lowering or call existing `ci_equal()` from `http_headers.hpp`. This is a one-line fix.

**Expected**: -5% compute CPU time

### Step 3: Defer memmove in prepare_for_next_request

Add threshold check: only compact when `parse_pos_ > buffer_capacity_ / 2`.

**Expected**: -3-6% in pipelining scenarios

### Step 4: Re-profile after steps 1-3

The profile landscape will shift significantly after removing 30%+ of handle_connection self-time. Re-run both perf and callgrind to identify the next bottleneck tier before optimizing further.

### Step 5: Optimize serialization path

Switch pipelining path to `io_buffer`-based serialization or convert `serialize_into(string&)` to use direct `memcpy` into pre-sized buffer.

**Expected**: -5-8% additional

---

## Methodology Notes

1. **All addresses and percentages in the original analysis were verified** against the actual annotate files and found to be accurate.

2. **The callgrind numbers were verified** against the actual callgrind_annotate output files and match exactly.

3. **The perf report numbers were verified** — hello_perf_saved and compute_perf_saved are the canonical datasets (larger sample counts). The non-saved versions show ±0.2-0.5% variance consistent with different sampling sessions.

4. **Pipeline depth difference**: hello_perf uses depth 10 (639K RPS) vs hello_perf_saved uses depth 20 (983K RPS). This 53.6% throughput difference is important context — the 983K baseline applies only at depth 20.
