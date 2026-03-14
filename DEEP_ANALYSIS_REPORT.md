# Deep E2E Profiling Report

## Scope

This report consolidates the deepest reliable profiling signal available from the
current VirtualBox Ubuntu guest for the two maintained E2E scenarios:

- `hello-canonical`
- `compute-canonical`

Artifacts used:

- `perf stat`
- `perf record` + `perf report`
- `perf script`
- `perf annotate` for hottest symbols
- `callgrind` reduced deterministic passes for instruction counts

Primary raw inputs:

- `manifest.json`
- `SUMMARY.md`
- `hello-canonical/record_pass/*`
- `compute-canonical/record_pass/*`
- `hello-canonical/callgrind_pass/*`
- `compute-canonical/callgrind_pass/*`

## Measurement Caveat

The guest VM does **not** expose PMU hardware events. On this machine,
`perf stat -e instructions:u,cycles:u,branches:u,branch-misses:u` returns
`<not supported>`.

That means:

- `perf` here is sampling on `cpu-clock:u`, not on retired instructions.
- The most trustworthy signal is the overlap between `perf` ranking and
  `callgrind` instruction counts.
- `callgrind` was intentionally run in reduced deterministic passes, not at the
  full `wrk -t4 -c512 -d10s` canonical load.

Despite that limitation, the profile is still strong because the same hotspots
repeat across both sampling and instrumentation.

## Executive Summary

### High-level result

`compute-canonical` is only about `22.4%` lower in throughput than
`hello-canonical`, but it consumes about `23.4%` more CPU-clock and its `p99`
latency is about `2.6x` worse.

That gap is **not** caused mainly by the arithmetic in `compute_sum`.
Most of the extra cost comes from:

- heavier request parsing,
- generated dispatch / validation overhead,
- header lookup and string normalization,
- JSON token/whitespace handling,
- response serialization that is still significant in both scenarios.

### Canonical E2E numbers

| Scenario | Req/s | P50 | P95 | P99 | CPU-clock |
|---|---:|---:|---:|---:|---:|
| `hello-canonical` | `1,310,914.98` | `2297 us` | `7456 us` | `10954 us` | `31.06 s` |
| `compute-canonical` | `1,017,712.55` | `3006 us` | `13262 us` | `28490 us` | `38.32 s` |

Derived deltas:

- Throughput drop, `hello -> compute`: `22.4%`
- P50 increase: `30.9%`
- P99 increase: `2.60x`
- CPU-clock increase: `23.4%`

## Scenario Breakdown

## Hello Canonical

### Strongest hotspots

From `perf`:

- `handle_connection(...)`: `16.67%`
- `parse_available()`: `16.40%`
- `dispatch_with_info(...)`: `11.85%`
- `response::serialize_into(...)`: `9.36%`
- `string_to_field(...)`: `6.00%`
- `prepare_for_next_request(...)`: `4.03%`

From `callgrind`:

- `handle_connection(...)`: `218,058,015 Ir` inclusive
- `response::serialize_into(...)`: `63,899,940 Ir` / `29.22%`
- `parse_available()`: `51,614,682 Ir` / `23.60%`
- `dispatch_with_info(...)`: `34,931,430 Ir` / `15.97%`
- `headers_map::get(...)`: `25,626,246 Ir` / `11.72%`
- `string_to_field(...)`: `16,198,386 Ir` / `7.41%`

### Interpretation

For the simplest route, the framework floor is already large. The major cost is:

- parsing the HTTP request bytes,
- routing / dispatch infrastructure,
- building the response string,
- mapping and re-reading headers.

This means the hello-world path is still materially paying for generic framework
machinery, not only for socket I/O.

## Compute Canonical

### Strongest hotspots

From `perf`:

- `parse_available()`: `31.67%`
- `handle_connection(...)`: `8.82%`
- `generated::dispatch_compute_sum(...)`: `8.20%`
- `response::serialize_into(...)`: `5.90%`
- `tolower`: `4.30%`
- `string_to_field(...)`: `4.26%`
- `json_cursor::skip_ws()`: `3.68%`
- `compute_handler::compute_sum(...)`: `3.48%`

From `callgrind`:

- `parse_available()`: `45,888,336 Ir` / `48.03%`
- `generated::dispatch_compute_sum(...)`: `19,598,885 Ir` / `20.51%`
- `response::serialize_into(...)`: `9,817,830 Ir` / `10.28%`
- `compute_handler::compute_sum(...)`: `5,508,305 Ir` / `5.76%`
- `json_cursor::skip_ws()` inside dispatch/serde: `1,645,800 Ir` direct child hot path
- `headers_map::get(...)`: `4,025,880 Ir` / `4.21%`
- `string_to_field(...)`: `4,306,206 Ir` / `4.51%`
- `tolower` in libc: `2,228,160 Ir` / `2.33%`

### Interpretation

The compute endpoint is still mostly paying for framework and generated binding
costs, not for the actual sum loop.

The arithmetic itself is visible but secondary:

- `compute_handler::compute_sum(...)`: `3.48%` perf / `5.76% Ir`

The real expansion versus hello comes from:

- more parser work on the request body,
- generated request dispatch and validation,
- JSON whitespace/token processing,
- case-insensitive media-type / header checks,
- the same response serialization path that already costs a lot in hello.

## Shared Framework Floor vs Compute-specific Cost

### Shared floor

These are dominant in **both** scenarios:

- `katana::http::server::handle_connection(...)`
- `katana::http::parser::parse_available()`
- `katana::http::response::serialize_into(...)`
- `katana::http::headers_map::get(...)`
- `katana::http::string_to_field(...)`

That means a large fraction of end-to-end time is common framework cost.

### Compute-specific additions

These are much more visible in `compute-canonical`:

- `generated::dispatch_compute_sum(...)`
- `katana::serde::json_cursor::skip_ws()`
- `tolower`
- `compute_handler::compute_sum(...)`

The important conclusion is that `compute` does **not** become slower mainly
because of math. It becomes slower because request handling becomes deeper and
more branchy before the math even starts.

## Code-level Evidence

## 1. Response serialization is a first-tier bottleneck

Source:

```cpp
void response::serialize_into(std::string& out) const {
    if (chunked) {
        out = serialize_chunked();
        ::katana::detail::syscall_metrics_registry::instance().note_response_serialize(
            out.size(), 0, out.capacity());
        return;
    }

    char content_length_buf[32];
    std::string_view content_length_value;
    bool has_content_length = headers.get("Content-Length").has_value();

    if (!has_content_length) {
        auto [ptr, ec] = std::to_chars(
            content_length_buf, content_length_buf + sizeof(content_length_buf), body.size());
        if (ec == std::errc()) {
            content_length_value =
                std::string_view(content_length_buf, static_cast<size_t>(ptr - content_length_buf));
        }
    }

    size_t headers_size = 0;
    for (const auto& [name, value] : headers) {
        headers_size += name.size() + HEADER_SEPARATOR.size() + value.size() + CRLF.size();
    }
```

Why it matters:

- Hello: `29.22% Ir`
- Compute: `10.28% Ir`
- Perf and callgrind both see downstream `std::string::append` and `memcpy`

This path is expensive even for tiny responses because it does:

- header lookup,
- header iteration,
- string growth and append,
- copies into final wire representation.

## 2. The parser hot loop is truly hot

Source:

```cpp
result<parser::state> parser::parse_available() {
    if (state_ == state::request_line || state_ == state::headers) [[likely]] {
        size_t validation_start = validated_bytes_;
        if (validation_start > 0) {
            --validation_start;
        }
        for (size_t i = validation_start; i < buffer_size_; ++i) {
            uint8_t byte = static_cast<uint8_t>(buffer_[i]);
            if (byte == 0 || byte >= 0x80) [[unlikely]] {
                return std::unexpected(make_error_code(error_code::invalid_fd));
            }
            if (byte == '\n' && (i == 0 || buffer_[i - 1] != '\r')) [[unlikely]] {
                return std::unexpected(make_error_code(error_code::invalid_fd));
            }
        }
        validated_bytes_ = buffer_size_;
    }
```

Perf annotate confirms the hot instructions are exactly in this loop:

- `test %sil,%sil`
- `jle`
- loop compare / branch
- CRLF checks

Compute is much worse than hello here:

- Hello: `23.60% Ir`
- Compute: `48.03% Ir`

So the parser is the largest single instruction sink in the compute path.

## 3. Router dispatch stays visible even for hello

Source:

```cpp
dispatch_with_info(const request& req, request_context& ctx, response& out) const {
    auto path = strip_query(req.uri);
    auto split = path_pattern::split_path(path);
    if (split.overflow) {
        return dispatch_result{make_error_code(error_code::not_found), true, false, 0};
    }

    const route_entry* best_route = nullptr;
    path_params best_params;
    int best_score = -1;

    for (const auto& entry : routes_) {
        if (entry.pattern.segment_count != split.count) {
            continue;
        }
        if (entry.method != req.http_method) {
            continue;
        }
        path_params candidate_params;
        if (!entry.pattern.match_segments(path_segments, split.count, candidate_params)) {
            continue;
        }
```

Signal:

- Hello: `15.97% Ir`, `11.85%` perf

For a hello-world route this is high. The generic two-phase dispatch path is
still materially visible, which means the simplest service is not yet on a truly
specialized fast path.

## 4. Header lookup and field normalization are not cheap helpers

Source:

```cpp
[[nodiscard]] std::optional<std::string_view> get(std::string_view name) const noexcept {
    field f = string_to_field(name);

    if (f == field::unknown) {
        if (const unknown_entry* entry = find_unknown_entry(name)) {
            return std::string_view(entry->value, entry->value_length);
        }
        return std::nullopt;
    }

    return get(f);
}
```

```cpp
field string_to_field(std::string_view name) noexcept {
    const auto& buckets = detail::get_popular_hash_table();
    const auto& bucket = buckets[detail::popular_hash(name)];
    for (size_t i = 0; i < bucket.size; ++i) {
        const auto& entry = bucket.entries[i];
        if (entry.name.size() == name.size() && ci_equal_fast(entry.name, name)) {
            return entry.value;
        }
    }

    const auto& rare = detail::get_rare_headers();
    auto it = std::lower_bound(
        rare.begin(), rare.end(), name, [](const detail::field_entry& entry, std::string_view n) {
            return detail::case_insensitive_less(entry.name, n);
        });
```

Signal:

- Hello:
  - `headers_map::get(...)`: `11.72% Ir`
  - `string_to_field(...)`: `7.41% Ir`
- Compute:
  - `headers_map::get(...)`: `4.21% Ir`
  - `string_to_field(...)`: `4.51% Ir`
  - `tolower`: `4.30%` perf, `2.33% Ir`

This is strong evidence that header access and case-insensitive normalization are
costing real end-to-end budget, not just background noise.

## 5. Generated compute dispatch adds a large non-math tax

Source:

```cpp
inline katana::result<void> dispatch_compute_sum(const katana::http::request& req,
                                                 katana::http::request_context& ctx,
                                                 api_handler& handler,
                                                 katana::http::response& out) {
    constexpr std::string_view kJsonContentType = "application/json";
    auto accept = req.headers.get(katana::http::field::accept);
    if (accept && !accept->empty() && *accept != "*/*" && *accept != kJsonContentType) {
        out.assign_error(katana::problem_details::not_acceptable("unsupported Accept header"));
        return {};
    }
    auto content_type = req.headers.get(katana::http::field::content_type);
    if (!content_type ||
        !katana::http_utils::detail::ascii_iequals(
            katana::http_utils::detail::media_type_token(*content_type), kJsonContentType)) {
        out.assign_error(
            katana::problem_details::unsupported_media_type("unsupported Content-Type"));
        return {};
    }
    auto parsed_body = parse_compute_sum_request(req.body, &ctx.arena);
    if (!parsed_body) {
        out.assign_error(katana::problem_details::bad_request("invalid request body"));
        return {};
    }
```

Signal:

- Perf: `8.20%`
- Callgrind: `20.51% Ir`

Perf annotate also shows repeated linear scans through inline header slots before
dispatch reaches the actual handler body. This function is carrying:

- Accept gating,
- Content-Type gating,
- case-insensitive token comparison,
- body parse,
- validation,
- context scope setup,
- response content-type fallback.

That is a major compute-specific overhead layer.

## 6. The actual math is not the main problem

Source:

```cpp
result<void> compute_sum(const compute_sum_request& nums, response& out) override {
    double acc = 0.0;
    for (double v : nums)
        acc += v;
    out.reset();
    out.status = 200;
    out.reason.assign(canonical_reason_phrase(200));
    out.body.clear();
    out.body.reserve(32);
    serialize_schema_into(acc, out.body);
    out.set_header(http::field::content_type, "application/json");
    return {};
}
```

Signal:

- Perf: `3.48%`
- Callgrind: `5.76% Ir`

The compute handler is visible, but it is **smaller** than:

- parser cost,
- generated dispatch cost,
- response serialization cost.

So if the goal is to move the endpoint materially, optimizing only the sum loop
is not enough.

## 7. JSON whitespace handling is branch-heavy and visible

Source:

```cpp
void skip_ws() noexcept {
    if (eof() || !is_json_whitespace(static_cast<unsigned char>(*ptr))) {
        return;
    }

    constexpr size_t simd_threshold = 8;
    const char* scan_ptr = ptr;
    size_t count = 0;
    while (count < simd_threshold && scan_ptr < end &&
           is_json_whitespace(static_cast<unsigned char>(*scan_ptr))) {
        ++scan_ptr;
        ++count;
    }
```

Signal:

- Perf: `3.68%`
- Callgrind child cost inside compute dispatch is clearly visible

Perf annotate shows a hot early-exit branch on the whitespace-table check:

- `cmpb $0x0,(%rdi,%rcx,1)`
- `je ... return`

That suggests `skip_ws()` is called often enough that even its fast path matters.

## Ranked Optimization Hypotheses

These are ordered by confidence, not by implementation ease.

### 1. Reduce response serialization work for stable response shapes

Why:

- Huge in hello, still large in compute
- Repeated header lookup, header iteration, append, memcpy

What to inspect first:

- [http.cpp](C:/Users/Ya/OneDrive/Desktop/KATANA/katana/core/src/http.cpp#L203)
- [http_headers.hpp](C:/Users/Ya/OneDrive/Desktop/KATANA/katana/core/include/katana/core/http_headers.hpp#L375)

### 2. Attack the scalar parser validation loop

Why:

- Biggest single sink in compute
- Still top-tier in hello
- Annotate points directly at the byte-walk loop

What to inspect first:

- [http.cpp](C:/Users/Ya/OneDrive/Desktop/KATANA/katana/core/src/http.cpp#L622)

### 3. Specialize the trivial routing fast path

Why:

- Hello still pays a lot for `dispatch_with_info`
- One-route services should not burn this much budget on generic path machinery

What to inspect first:

- [router.hpp](C:/Users/Ya/OneDrive/Desktop/KATANA/katana/core/include/katana/core/router.hpp#L336)

### 4. Cut header normalization / lookup overhead

Why:

- `headers_map::get` and `string_to_field` are visible in both scenarios
- `tolower` shows up in compute because media-type / header comparisons are expensive enough

What to inspect first:

- [http_headers.hpp](C:/Users/Ya/OneDrive/Desktop/KATANA/katana/core/include/katana/core/http_headers.hpp#L375)
- [http_field.cpp](C:/Users/Ya/OneDrive/Desktop/KATANA/katana/core/src/http_field.cpp#L501)

### 5. Shrink generated dispatch overhead before the handler body

Why:

- `dispatch_compute_sum` is larger than `compute_sum` itself
- Header gating + body parse + validation are all visible

What to inspect first:

- [generated_router_bindings.hpp](C:/Users/Ya/OneDrive/Desktop/KATANA/examples/codegen/compute_api/generated/generated_router_bindings.hpp#L64)
- [main.cpp](C:/Users/Ya/OneDrive/Desktop/KATANA/examples/codegen/compute_api/main.cpp#L23)

## Confidence

High-confidence conclusions:

- `parse_available` is a dominant bottleneck
- `serialize_into` is a dominant bottleneck
- `dispatch_with_info` is too visible for hello
- `dispatch_compute_sum` is a major compute-specific cost
- `compute_sum` arithmetic is not the main limiter
- header normalization / lookup is materially expensive

Medium-confidence conclusions:

- `skip_ws` fast-path behavior is worth redesigning or fusing
- repeated Accept / Content-Type policy checks may be too expensive relative to endpoint work

Low-confidence / excluded:

- syscall profile in this VM
  - I attempted a `strace -c` pass, but the tracer lifecycle with long-lived
    server children was not reliable enough in this guest to trust the summary.
  - I excluded that line of evidence from the ranking above.

## Final Takeaway

The dominant story is not "compute is slow because the computation is heavy".

The dominant story is:

- KATANA already spends a lot of work on generic HTTP parsing, routing, header
  normalization, and response construction even for hello-world.
- The compute endpoint adds another substantial layer of generated dispatch and
  JSON/body validation overhead before the actual sum loop runs.
- On this workload, the framework floor is high enough that the endpoint logic is
  only one part of the total budget.

If the goal is a meaningful improvement in both scenarios, the first places to
push are parser, serializer, router fast path, and header normalization. The
actual business computation in `compute_sum` is not the primary lever.
