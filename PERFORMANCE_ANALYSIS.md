# KATANA HTTP Server — Performance Analysis Report

**Date**: 2026-03-14
**Analyst**: AI Performance Engineer
**Scope**: E2E profiling of Hello World and Compute API scenarios
**Tools**: `perf record -e cpu-clock:u` + `perf annotate`, `callgrind` via in-process harness

---

## 1. Executive Summary

### Benchmark Results

| Metric | Hello World | Compute API | Delta |
|--------|-------------|-------------|-------|
| **RPS** | 983,015 | 850,798 | -13.4% |
| **Avg Latency** | 4.13ms | 4.43ms | +7.3% |
| **P99 Latency** | 13.9ms | 20.4ms | +46.8% |
| **P999 Latency** | 19.7ms | 103.2ms | +424% |
| **Total Ir (callgrind)** | 336.7M | 665.1M | +97.5% |

### Top 3 Bottlenecks

1. **Per-request object initialization (rep stos / zeroing loops)** — 30-40% of `handle_connection` self-time is spent zeroing `response`, `headers_map`, and `request_context` objects on every request. This is the single largest self-time hotspot in the annotate output.

2. **HTTP parser (`parse_available()`)** — 40-48% of all instructions (callgrind). Dominates both scenarios. Driven by CRLF scanning, header field lookup (`string_to_field` + `tolower` in compute), and buffer management.

3. **Response serialization (`serialize_into(std::string&)`)** — 13% perf overhead (hello), ~70M instructions per scenario. Multiple `std::string::append()` calls with potential reallocations despite `reserve()`.

### What Limits Latency Most

The P999 tail latency spike in compute (103ms vs 20ms in hello) suggests that occasional requests trigger expensive paths — likely JSON parsing with arena allocation pressure, or `std::string::reserve()` causing `malloc()` on the response body path.

### What Limits RPS Most

Per-request object zeroing + parser instruction count. Every request pays ~290-620K instructions in `handle_connection` inclusive cost. The zeroing of `headers_map` arrays (16 known_entry + 8 unknown_entry inline slots × 24 bytes each = 576 bytes of zero-fill per response) happens in the hottest loop.

### Top 3 Changes to Make First

1. **Eliminate per-request zeroing** — reuse response/request objects with explicit `reset()` instead of constructing new ones
2. **Switch to `io_buffer`-based serialization** in the pipelining path (already exists but unused for `std::string` path)
3. **Pre-lower header names in parser** — avoid `tolower`/`string_to_field` costs by normalizing during parse

---

## 2. Profiling Synthesis

### Hello World — Hot Functions

| Rank | Function | perf % | callgrind Ir | Source |
|------|----------|--------|-------------|--------|
| 1 | `handle_connection` (self) | 25.30% | 289M (incl) | perf report, annotate |
| 2 | `serialize_into(string&)` | 13.28% | 70M | perf report, callgrind |
| 3 | `parse_available()` | 10.14% | 137M | perf report, callgrind |
| 4 | `prepare_for_next_request()` | 6.45% | - | perf report |
| 5 | `__memmove_avx_unaligned_erms` | 6.03% | - | perf report |
| 6 | `handle_root` (user handler) | 4.13% | - | perf report |
| 7 | `headers_map::get()` | 2.65% | - | perf report |
| 8 | `string::append()` (2 clones) | 4.05% | - | perf report |
| 9 | `headers_map::set_known_borrowed` | 1.86% | 13.5M | perf report, callgrind |

### Compute API — Hot Functions

| Rank | Function | perf % | callgrind Ir | Source |
|------|----------|--------|-------------|--------|
| 1 | `parse_available()` | 23.06% | 322M | perf report, callgrind |
| 2 | `handle_connection` (self) | 10.56% | 620M (incl) | perf report, annotate |
| 3 | `dispatch_compute_sum()` | 10.44% | 155M | perf report, callgrind |
| 4 | `serialize_into(string&)` | 6.39% | 137M | perf report, callgrind |
| 5 | `tolower` | 5.19% | - | perf report |
| 6 | `json_cursor::skip_ws()` | 4.28% | - | perf report |
| 7 | `compute_sum()` | 4.15% | 43M | perf report, callgrind |
| 8 | `__memmove_avx_unaligned_erms` | 3.78% | - | perf report |
| 9 | `string_to_field()` | 2.42% | 6.6M | perf report, callgrind |

### Key Differences Between Scenarios

- **Parser share doubles**: 10% → 23% (perf), because compute requests have larger bodies with more headers (Content-Type, Accept, etc.)
- **`tolower` appears only in compute** (5.19%): The compute path calls `string_to_field()` which internally uses `tolower` for case-insensitive header matching on unknown/overflow headers
- **JSON parsing overhead**: `json_cursor::skip_ws()` at 4.28% + `dispatch_compute_sum` at 10.44% are compute-specific costs
- **Serialization cost is constant**: ~70M instructions in both — this is proportional to response header count, not body size

### Why perf and callgrind emphasize differently

- `perf` uses CPU-clock sampling (wall-clock proportional) and captures syscall wait time. This is why `handle_connection` self-time is high at 25% — it includes time waiting on `recv()` that returns EAGAIN.
- `callgrind` counts retired instructions only (no I/O wait). This is why `parse_available()` dominates callgrind (48%) but not perf (23%) — parsing is pure CPU work.
- **Implication**: For RPS optimization, trust callgrind instruction counts. For latency optimization, trust perf overhead %.

---

## 3. Findings

### Finding F1: Per-Request Object Zeroing Dominates handle_connection Self-Time

**Confidence**: HIGH

**Evidence**:
From `hello_perf_saved/annotate_handle_connection.txt`:
```
18.81% :   23d5e:  rep stos %rax,%es:(%rdi)   ← zeroing headers_map known_inline_[16]
12.16% :   23de0:  rep stos %rax,%es:(%rdi)   ← zeroing response unknown headers
 8.47% :   23e03:  rep stos %rax,%es:(%rdi)   ← zeroing request_context fields
 4.22% :   23da7:  movq $0x0,0x8(%rax)        ← zeroing known_entry loop
 3.65% :   23daf:  add $0x18,%rax             ← loop increment
 4.86% :   23dbb:  cmp %rbx,%rax              ← loop comparison
```
Combined: **~52% of handle_connection self-time** is spent in zero-initialization.

From `compute_perf_saved/annotate_handle_connection.txt`:
```
15.71% :   25e1e:  rep stos
 9.40% :   25ea7:  rep stos
 7.22% :   25eca:  rep stos
 3.02% :   25e67:  movq $0x0,0x8(%rax)
 2.95% :   25e6f:  add $0x18,%rax
 4.00% :   25e7b:  cmp %rbx,%rax
```
Combined: **~42% of handle_connection self-time**.

**Code Location**:
- `core/src/http_server.cpp:410-411` — `response resp{&state.arena}` and `request_context ctx{state.arena}` constructed per request
- `core/include/katana/core/http_headers.hpp:228-231` — `known_inline_` is `std::array<known_entry, 16>` = 16 × 24 bytes = 384 bytes zeroed
- `core/include/katana/core/http_headers.hpp:230` — `unknown_inline_` is `std::array<unknown_entry, 8>` = 8 × 24 bytes = 192 bytes zeroed

**Root Cause**: Every request constructs a new `response` and `request_context` on the stack. The `headers_map` default constructor zero-initializes its inline arrays via aggregate initialization (`std::array<known_entry, 16> known_inline_{}`). The compiler generates `rep stos` (memset to zero) for these ~576+ bytes of inline storage.

**Suggested Fix**:
Pre-allocate `response` and `request_context` in `connection_state` and add a fast `reset()` method that only clears the `known_size_`/`unknown_size_` counters without touching the actual array data. The array entries are guarded by `known_size_` anyway — if size is 0, no entries are read.

```cpp
// Instead of constructing per request:
// response resp{&state.arena};

// Keep in connection_state:
// response reusable_response{&arena};
// request_context reusable_ctx{arena};

// Add to headers_map:
void fast_reset() noexcept {
    // Only reset counters — entries will be overwritten on use
    known_size_ = 0;
    unknown_size_ = 0;
    known_chunks_ = nullptr;
    unknown_chunks_ = nullptr;
}
```

**Expected Impact**: LARGE — eliminates ~40-50% of `handle_connection` self-time
**Complexity**: LOW — purely additive change, doesn't affect external API
**Risk**: LOW — existing iteration already checks `known_size_`

---

### Finding F2: Parser Instruction Count is the RPS Ceiling

**Confidence**: HIGH

**Evidence**:
- Hello: 137M/337M total = 40.7% of all instructions
- Compute: 322M/665M total = 48.4% of all instructions
- `parse_available()` is called twice per request when data arrives incrementally (once returning incomplete, once after `recv`)

**Code Location**: `core/src/http.cpp` — `parse_available()` state machine

**Root Cause**: The parser does byte-by-byte validation (`contains_invalid_header_value`, `contains_invalid_uri_char`), repeated CRLF scanning via `simd::find_crlf_avx2()`, and per-header `string_to_field()` lookup. For the compute scenario with ~6-8 headers per request, this means 6-8 hash lookups + 6-8 CRLF scans per request.

**Suggested Fix** (multi-part):

a) **Cache CRLF positions**: After finding the header terminator (`\r\n\r\n`), build a small array of line offsets in one pass, then process headers from the offset array instead of re-scanning.

b) **Combine validation + parsing**: Currently `contains_invalid_header_value()` is a separate loop from the actual parse. Validate bytes as part of the parsing loop instead of a separate pass.

c) **Reduce `string_to_field()` calls**: The popular hash table (64 entries) already handles the 25 most common headers. For the remaining, the binary search over 342 entries could be replaced with a perfect hash if the set is known at compile time.

**Expected Impact**: MEDIUM — 10-20% reduction in parser instructions
**Complexity**: MEDIUM — parser state machine is complex, changes need careful validation
**Risk**: MEDIUM — incorrect parsing can cause security issues

---

### Finding F3: `tolower` in Compute Path (5.19% perf overhead)

**Confidence**: HIGH

**Evidence**: `tolower` appears at 5.19% in compute perf report but is absent from hello. This is because compute requests have more headers including custom ones that hit the slow path of `string_to_field()`.

**Code Location**: `core/include/katana/core/http_field.hpp` — `string_to_field()` slow path uses `to_lower()` which calls `tolower` per character

**Root Cause**: `to_lower()` in `http_headers.hpp:171-178` allocates a new `std::string` and calls `push_back()` per character. The libc `tolower()` function does locale-aware lookup on each call.

**Suggested Fix**:
Replace `to_lower()` with an inline ASCII-only lowering that operates on the raw bytes without allocation:
```cpp
// In the binary search path, use ci_equal() directly instead of lowering first
// Or: add a fast inline lowercase that avoids locale lookup
inline char fast_ascii_lower(char c) noexcept {
    return (c >= 'A' && c <= 'Z') ? (c | 0x20) : c;
}
```
The code already has `ascii_lower()` in `http_headers.hpp:31-33` — the issue is that `to_lower()` at line 171 creates a `std::string` copy instead of doing in-place comparison.

**Expected Impact**: MEDIUM — eliminates 5% CPU overhead in compute path
**Complexity**: LOW — swap `to_lower()` for SIMD `ci_equal()` in binary search
**Risk**: LOW — ASCII-only lowering is correct for HTTP header names per RFC 7230

---

### Finding F4: Response Serialization Uses String Append Path

**Confidence**: HIGH

**Evidence**:
- Hello: `serialize_into(string&)` at 13.28% perf + 70M callgrind Ir
- Multiple `string::append()` clones visible: 2.63% + 1.42% + 0.76% = ~4.8% additional

**Code Location**: `core/src/http.cpp:217-282` — `response::serialize_into(std::string&)`

**Root Cause**: The code does `out.reserve(...)` then 10+ separate `out.append(...)` calls. While `reserve()` prevents reallocation, each `append()` still does bounds checking, size updates, and potential memcpy. The code already has a zero-copy `serialize_into(io_buffer&)` path at line 342 that uses pre-calculated sizes and direct memcpy, but the pipelining path in `handle_connection` uses the `std::string` variant.

**Suggested Fix**:
Replace the `std::string` serialization path with direct `memcpy` into a pre-sized buffer:
```cpp
void response::serialize_into(std::string& out) const {
    // Calculate exact size
    size_t total = /* ... */;
    out.resize(out.size() + total);  // Single allocation
    char* ptr = out.data() + out.size() - total;
    // Direct memcpy for each component
    std::memcpy(ptr, HTTP_VERSION_PREFIX.data(), HTTP_VERSION_PREFIX.size());
    ptr += HTTP_VERSION_PREFIX.size();
    // ... etc
}
```

**Expected Impact**: MEDIUM — could reduce serialize_into from 13% to ~8% by eliminating append overhead
**Complexity**: LOW — straightforward refactor of existing code
**Risk**: LOW — same output, just different write strategy

---

### Finding F5: `prepare_for_next_request` memmove (6.45% hello)

**Confidence**: HIGH

**Evidence**: 6.45% in hello perf report, 2.54% in compute. Also `__memmove_avx_unaligned_erms` at 6.03%/3.78%.

**Code Location**: `core/src/http.cpp:1174-1183`

```cpp
void parser::prepare_for_next_request(monotonic_arena* arena) noexcept {
    size_t remaining = buffered_bytes();
    if (remaining == 0) {
        buffer_size_ = 0;
    } else if (parse_pos_ > 0) {
        std::memmove(buffer_, buffer_ + parse_pos_, remaining);
        buffer_size_ = remaining;
    }
    reset_message_state(arena);
}
```

**Root Cause**: After each request, remaining unparsed bytes are moved to the front of the buffer. With pipelining (20 requests in flight for hello), this means 19 memmove operations per batch, each moving progressively smaller amounts of data.

**Suggested Fix**:
Use a circular/ring buffer or double-buffer scheme to avoid memmove. Alternatively, defer compaction until `parse_pos_` exceeds half the buffer capacity:
```cpp
void parser::prepare_for_next_request(monotonic_arena* arena) noexcept {
    // Only compact when fragmentation is severe
    if (parse_pos_ > buffer_capacity_ / 2) {
        size_t remaining = buffered_bytes();
        std::memmove(buffer_, buffer_ + parse_pos_, remaining);
        buffer_size_ = remaining;
        parse_pos_ = 0;
    }
    reset_message_state(arena);
}
```

**Expected Impact**: SMALL-MEDIUM — reduces memmove calls by ~80% in pipelining scenarios
**Complexity**: LOW — simple threshold change
**Risk**: LOW — buffer capacity is already maintained

---

### Finding F6: Connection Header Linear Scan (unrolled cmpw chain)

**Confidence**: HIGH

**Evidence**: From annotate output, there's a long unrolled sequence of `cmpw $0x3b` instructions (0x3b = 59 = field::connection) scanning through both request and response headers_map inline arrays. This accounts for ~5% of annotate samples across both known_inline_ and unknown_inline_ scans.

Lines 227-398 in hello annotate show ~40 sequential `cmpw $0x3b` comparisons.

**Code Location**: `core/include/katana/core/http_headers.hpp` — `contains()` / `get()` / `find_known_entry()` functions that do linear scan through the 16 inline entries + overflow chunks.

**Root Cause**: `headers.contains(http::field::connection)` is called twice per request (once for request headers, once for response headers). Each call scans all 16 inline + any overflow entries. With the compiler unrolling the loop, this creates a 40+ instruction sequence.

**Suggested Fix**:
Add a direct-indexed fast path for the most frequently checked fields. Since `field` is an enum (uint16_t), use a bitset or direct array indexed by field value:
```cpp
// Add to headers_map:
uint64_t known_present_mask_ = 0;  // Bitset for field IDs < 64

bool contains(field f) const noexcept {
    if (static_cast<uint16_t>(f) < 64) {
        return (known_present_mask_ >> static_cast<uint16_t>(f)) & 1;
    }
    return find_known_entry(f) != nullptr;
}
```

**Expected Impact**: SMALL — eliminates ~3-5% of handle_connection self-time
**Complexity**: LOW — additive change, maintain mask in set_known/set_known_borrowed
**Risk**: LOW — purely additive optimization

---

### Finding F7: `malloc`/`free` in Response Cleanup Loop

**Confidence**: MEDIUM

**Evidence**: From annotate, the cleanup loop at offset 0x24490-0x244a9 (hello) shows:
```
11.43% :   24494:  sub $0x18,%rbx    ← iterating backwards through unknown headers
 2.19% :   2449b:  je  249e0         ← null check (skip free)
```
This is the loop that frees arena-allocated overflow header chunks. Similar pattern at compute 0x2655c (8.35%) + 0x2655f (1.19%).

**Code Location**: `handle_connection` cleanup path — freeing `entry_chunk` linked list nodes

**Root Cause**: The unknown headers overflow chunks are allocated via arena but the response headers use `owned_arena_`. When the response object is destroyed (stack unwinding), its `headers_map` destructor iterates and frees chunks. With 8+ headers in compute, this path is triggered more frequently.

**Suggested Fix**: Already partially addressed by F1 (reuse response object). Additionally, ensure chunk memory is arena-allocated so cleanup is O(1) arena reset instead of per-chunk free.

**Expected Impact**: MEDIUM — eliminates ~8-11% of handle_connection self-time
**Complexity**: LOW — tied to F1 fix
**Risk**: LOW

---

### Finding F8: JSON Whitespace Skipping (4.28% compute only)

**Confidence**: MEDIUM

**Evidence**: `katana::serde::json_cursor::skip_ws()` at 4.28% in compute perf report.

**Code Location**: `core/include/katana/core/serde.hpp` — `json_cursor::skip_ws()`

**Root Cause**: The JSON parser calls `skip_ws()` between every token. If the implementation is byte-by-byte, this is O(n) per call where n is the number of whitespace characters.

**Suggested Fix**: Use SIMD to scan for non-whitespace characters:
```cpp
void skip_ws() noexcept {
    // AVX2: compare 32 bytes against whitespace set
    // Skip to first non-space/tab/cr/lf byte
}
```

**Expected Impact**: SMALL — 2-3% reduction in compute path
**Complexity**: LOW — isolated function
**Risk**: LOW

---

### Finding F9: `std::to_chars(double)` in Compute Response (2.15%)

**Confidence**: MEDIUM

**Evidence**: `std::to_chars()` at 2.15% in compute callgrind, 0.13% perf. Only in compute path.

**Code Location**: Compute handler's response body generation — converting double result to JSON string.

**Root Cause**: `std::to_chars()` for doubles uses Ryu or Dragonbox algorithm in libstdc++, which is reasonably fast but still ~100-200 instructions per conversion.

**Suggested Fix**: If the result precision is bounded (e.g., 6 decimal digits), use a fixed-point fast path:
```cpp
// Fast path for integers that happen to be doubles
if (value == std::floor(value) && value < 1e15) {
    return format_int_fast(static_cast<int64_t>(value), buf);
}
```

**Expected Impact**: TINY-SMALL
**Complexity**: LOW
**Risk**: LOW

---

### Finding F10: Syscall Metrics Overhead (1.46% hello, 0.71% compute)

**Confidence**: MEDIUM

**Evidence**: `syscall_metrics_registry::local_slot()` at 1.46% (hello) and `instance()` at 0.26%.

**Code Location**: `core/include/katana/core/detail/syscall_metrics.hpp`, `core/src/syscall_metrics.cpp`

**Root Cause**: Every `recv()` and `send()` call is instrumented with `local_slot()` which does a thread-local lookup + atomic increment (`lock incq`). This is on every single I/O operation.

**Suggested Fix**: Make metrics sampling-based (1 in N calls) or compile-out in release builds:
```cpp
#ifdef KATANA_ENABLE_METRICS
    auto* slot = registry.local_slot();
    if (slot) { slot->count.fetch_add(1, std::memory_order_relaxed); }
#endif
```

**Expected Impact**: SMALL — 1-2% reduction
**Complexity**: LOW — preprocessor guard
**Risk**: LOW — metrics are for debugging

---

## 4. Optimization Plan

### Quick Wins (1-2 days each, low risk)

| # | Change | Expected Impact | Files |
|---|--------|----------------|-------|
| Q1 | Add `fast_reset()` to `headers_map`, reuse response objects | LARGE (30-40% of handle_connection self) | http_headers.hpp, http_server.cpp |
| Q2 | Replace `to_lower()` with `ci_equal()` in `string_to_field()` slow path | MEDIUM (5% compute) | http_field.hpp/cpp |
| Q3 | Defer `prepare_for_next_request` memmove until fragmentation > 50% | SMALL-MEDIUM (3-6%) | http.cpp |
| Q4 | Compile-out syscall metrics in release | SMALL (1-2%) | syscall_metrics.hpp |
| Q5 | Add `known_present_mask_` bitset to headers_map for O(1) `contains()` | SMALL (3-5%) | http_headers.hpp |

### Medium-Effort Changes (3-5 days each)

| # | Change | Expected Impact | Files |
|---|--------|----------------|-------|
| M1 | Switch pipelining path to `io_buffer`-based serialization | MEDIUM (5-8%) | http_server.cpp, http.cpp |
| M2 | Single-pass header parsing: combine validation + CRLF scan + field lookup | MEDIUM (10-15% parser) | http.cpp |
| M3 | SIMD `skip_ws()` for JSON parser | SMALL (2-3% compute) | serde.hpp |
| M4 | Pre-allocate connection state buffers (response_scratch, active_response) with thread-local pool | SMALL (reduce malloc pressure) | http_server.cpp |

### Deep Changes (1-2 weeks each)

| # | Change | Expected Impact | Files |
|---|--------|----------------|-------|
| D1 | Replace parser state machine with table-driven parser (like `picohttpparser`) | LARGE (30-50% parser reduction) | http.cpp, http.hpp |
| D2 | Circular buffer for parser input (eliminate memmove entirely) | MEDIUM | http.hpp, http.cpp |
| D3 | `io_uring` for zero-copy send (already have reactor) | MEDIUM-LARGE (eliminate send syscall) | io_uring_reactor.cpp |
| D4 | HTTP/2 or vectored response (send headers + body in one writev call) | MEDIUM | http_server.cpp |

---

## 5. Validation Plan

### After Each Change

1. **Re-run wrk benchmarks** with identical parameters:
   - Hello: `wrk -t4 -c100 -d10s --latency -s pipeline.lua -- http://localhost:PORT/ 20`
   - Compute: `wrk -t4 -c100 -d10s --latency http://localhost:PORT/compute/sum` with JSON body

2. **Compare metrics**:
   - RPS (higher is better)
   - P50, P99, P999 latency (lower is better)
   - Transfer rate
   - Error count (must remain 0)

### After Quick Wins (Q1-Q5)

3. **Re-run callgrind** via E2E harness:
   ```
   valgrind --tool=callgrind --callgrind-out-file=callgrind.out.post ./harness_hello
   callgrind_annotate --auto=yes --inclusive=yes --show=Ir callgrind.out.post
   ```
   Compare total Ir and per-function breakdown.

4. **Re-run perf annotate** on `handle_connection`:
   ```
   perf record -e cpu-clock:u -g ./server &
   wrk ...
   perf annotate katana::http::server::handle_connection
   ```
   Verify `rep stos` percentage dropped to near-zero.

### After Medium Changes (M1-M4)

5. **Run flamegraph** to visualize new hot paths:
   ```
   perf script | stackcollapse-perf.pl | flamegraph.pl > flame_post.svg
   ```

6. **Measure allocation rate** with `perf stat -e malloc`:
   ```
   LD_PRELOAD=libjemalloc.so MALLOC_CONF=stats_print:true ./server
   ```

### After Deep Changes (D1-D4)

7. **Run under ThreadSanitizer and AddressSanitizer** to verify correctness:
   ```
   cmake -DCMAKE_CXX_FLAGS="-fsanitize=thread" ..
   cmake -DCMAKE_CXX_FLAGS="-fsanitize=address" ..
   ```

8. **HTTP conformance test** (e.g., h2spec for HTTP/1.1 subset, or custom test suite) to ensure parser changes don't break RFC compliance.

### Metrics to Compare

| Metric | Baseline Hello | Baseline Compute | Target Hello | Target Compute |
|--------|---------------|------------------|-------------|----------------|
| RPS | 983K | 851K | >1.1M | >950K |
| P99 | 13.9ms | 20.4ms | <10ms | <15ms |
| P999 | 19.7ms | 103.2ms | <15ms | <50ms |
| Total Ir | 337M | 665M | <250M | <500M |

---

## 6. Patch Candidates

### Patch 1: Eliminate Per-Request Zeroing (Q1) — Highest ROI

**File**: `core/include/katana/core/http_headers.hpp`

Add fast reset method:
```cpp
class headers_map {
public:
    // ... existing methods ...

    /// Reset without zeroing inline arrays.
    /// Safe because iteration uses known_size_/unknown_size_ as bounds.
    void fast_reset() noexcept {
        known_size_ = 0;
        unknown_size_ = 0;
        // Free overflow chunks back to arena (or just abandon if arena-allocated)
        known_chunks_ = nullptr;
        unknown_chunks_ = nullptr;
    }
};
```

**File**: `core/include/katana/core/http.hpp`

Add reset to response:
```cpp
struct response {
    // ... existing members ...

    void reset(monotonic_arena* arena) noexcept {
        status = 200;
        reason.clear();
        headers.fast_reset();
        // Re-associate arena if needed
        body.clear();
        chunked = false;
    }
};
```

**File**: `core/src/http_server.cpp`

Reuse response in connection loop:
```cpp
// In handle_connection, before the while(true) loop:
response resp{&state.arena};
request_context ctx{state.arena};

// Inside the loop, replace construction with reset:
resp.reset(&state.arena);
ctx.reset();  // Similar fast_reset for request_context
```

### Patch 2: Eliminate `to_lower` Allocation (Q2)

**File**: `core/src/http_field.cpp` (or wherever `string_to_field` slow path is)

Replace:
```cpp
// Before: allocates std::string via to_lower()
auto lower = to_lower(name);
auto it = std::lower_bound(rare_headers.begin(), rare_headers.end(), lower);
```

With:
```cpp
// After: use ci_equal directly in binary search comparator
auto it = std::lower_bound(rare_headers.begin(), rare_headers.end(), name,
    [](const auto& entry, std::string_view target) {
        // Case-insensitive comparison for binary search
        return ci_less(entry.name, target);
    });
if (it != rare_headers.end() && ci_equal(it->name, name)) {
    return it->field_id;
}
```

### Patch 3: Deferred Buffer Compaction (Q3)

**File**: `core/src/http.cpp`

```cpp
void parser::prepare_for_next_request(monotonic_arena* arena) noexcept {
    // Don't move data if parse position is small
    // This avoids memmove on every pipelined request
    size_t remaining = buffered_bytes();
    if (remaining == 0) {
        buffer_size_ = 0;
        parse_pos_ = 0;
    } else if (parse_pos_ > buffer_capacity_ / 2) {
        // Only compact when we've consumed more than half the buffer
        std::memmove(buffer_, buffer_ + parse_pos_, remaining);
        buffer_size_ = remaining;
        parse_pos_ = 0;
    } else {
        // Keep parse_pos_ as-is, just reset message state
        buffer_size_ = parse_pos_ + remaining;
    }
    reset_message_state(arena);
}
```

---

## Methodological Notes

1. **VM limitation**: All measurements were taken on a VirtualBox VM without hardware PMU counters. The `perf` data uses `cpu-clock:u` sampling, which is wall-clock proportional and includes some measurement overhead. Results should be treated as relative signals, not absolute instruction counts.

2. **Callgrind via harness**: Because daemon-style servers don't produce clean `callgrind.out`, the callgrind data was collected via an in-process harness that sends a fixed number of localhost requests. This is a valid approach but may not capture contention effects that appear under real concurrent load.

3. **Pipelining depth**: Hello World was tested with pipeline depth 20, compute with depth 10. This explains some of the difference in `prepare_for_next_request` overhead (more memmoves with deeper pipelining).

4. **Compiler optimizations**: The binary shows LTO (link-time optimization) effects — many functions are inlined (`.isra.0`, `.part.0`, `.lto_priv.0` clones). This means some "function" costs in perf report are actually inlined code, and the callgrind inclusive costs may differ from what the source-level function boundaries suggest.

---

## Most Suspicious Files to Inspect Next

1. `core/include/katana/core/http_field.hpp` — the `string_to_field()` slow path binary search + `tolower`
2. `core/include/katana/core/serde.hpp` — `json_cursor::skip_ws()` and `parse_double()` implementation
3. `core/include/katana/core/handler_context.hpp` — `request_context` struct and its initialization cost
4. `core/include/katana/core/router.hpp` — `dispatch_with_info()` route matching (not yet profiled separately)

## Suggested Experiment Sequence

1. Apply Q1 (fast_reset) → measure → expect ~15-20% RPS improvement
2. Apply Q2 (tolower elimination) → measure → expect ~5% compute improvement
3. Apply Q3 (deferred compaction) → measure → expect ~3% hello improvement
4. Apply Q5 (contains bitset) → measure → expect ~2-3% improvement
5. Re-profile with callgrind → identify next bottleneck tier
6. Apply M1 (io_buffer serialization) → measure → expect ~5-8% improvement
7. Apply M2 (single-pass parser) → measure → expect ~10% parser improvement
