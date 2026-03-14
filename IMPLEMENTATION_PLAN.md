# KATANA Optimization Implementation Plan

На основе PERFORMANCE_REVIEW.md и DEEP_ANALYSIS_REPORT.md.

---

## Phase 0: Verification — Baseline Lock-in

### Цель
Зафиксировать воспроизводимый baseline для всех последующих сравнений.

### Действия

1. **Запустить canonical benchmarks 3 раза, взять median:**
   ```bash
   for i in 1 2 3; do
     wrk -t4 -c512 -d10s http://127.0.0.1:8080/ > hello_run_$i.txt 2>&1
   done
   for i in 1 2 3; do
     wrk -t4 -c512 -d10s -s compute_payload.lua http://127.0.0.1:8081/compute/sum > compute_run_$i.txt 2>&1
   done
   ```

2. **Снять callgrind baseline для обоих сценариев:**
   ```bash
   valgrind --tool=callgrind --callgrind-out-file=hello_baseline.callgrind ./hello_server &
   # send reduced load
   wrk -t1 -c1 -d3s http://127.0.0.1:8080/
   kill %1
   callgrind_annotate hello_baseline.callgrind > hello_baseline_annotate.txt
   ```

3. **Зафиксировать commit hash в лог.**

### Критерий успеха
- Все 3 прогона hello отличаются не более чем на 10%.
- callgrind Ir детерминистичен (±0.1%).
- Файлы baseline сохранены в `benchmarks/baseline/`.

### Тесты
- Существующий E2E test suite (если есть).
- Manual curl smoke test: `curl http://127.0.0.1:8080/` → 200 OK.

---

## Phase 1: Quick Wins — 30 минут, Low Risk

### Цель
Три точечных правки, zero-risk, суммарный ожидаемый выигрыш: **+5-8% throughput** в обоих сценариях.

---

### 1.1 Replace string-based header lookups with `field` enum

**Файлы:**
- `http.cpp` — строка 214
- `http.cpp` — строка 278
- `http_server.cpp` — строка 418, 420, 422

**Функции:**
- `response::serialize_into(std::string&)` — строка 214
- `response::serialize_head_into(std::string&)` — строка 278
- `handle_connection(...)` — строки 418-422

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

#### http_server.cpp:418-422 (handle_connection)
```diff
-        auto connection_header = req.headers.get("Connection");
+        auto connection_header = req.headers.get(http::field::connection);
         bool close_connection =
             connection_header && (*connection_header == "close" || *connection_header == "Close");

-        if (!resp.headers.get("Connection")) {
+        if (!resp.headers.contains(http::field::connection)) {
```

**Почему это поможет:**
- `get(string_view)` → `string_to_field()` → hash → bucket scan → `ci_equal_fast` (с fallback на binary search по 342 rare headers).
- `get(field)` → прямой linear scan по `known_inline_` (max 16 entries), без hashing и string comparison.
- `contains(field)` → `find_known_entry(f) != nullptr` — ещё быстрее, нет создания `optional<string_view>`.
- Evidence: `string_to_field` = 7.41% Ir в hello, 4.51% в compute. Каждый вызов `get("Content-Length")` вызывает полный hash + scan.

**Ожидаемый выигрыш:**
- Conservative: +2% throughput
- Realistic: +3-5% throughput
- Optimistic: +8% throughput

**Риск регрессий:** Нулевой. API `get(field)` и `contains(field)` уже существуют и используются в других местах. `field::content_length` и `field::connection` — стандартные enum values.

**Тесты после:**
```bash
# callgrind: string_to_field Ir должен уменьшиться
callgrind_annotate ... | grep string_to_field
# wrk: сравнить median throughput
```

**Критерий успеха:** `string_to_field` Ir в hello уменьшается на ≥30% (потеря 2-3 вызовов на каждый request-response cycle).

---

### 1.2 Replace `std::tolower` with branchless ASCII lowering in `ci_char_equal`

**Файл:** `http_headers.hpp` — строки 31-34

**Функция:** `ci_char_equal(char a, char b)`

**Что заменить → на что:**

```diff
 inline bool ci_char_equal(char a, char b) noexcept {
-    return std::tolower(static_cast<unsigned char>(a)) ==
-           std::tolower(static_cast<unsigned char>(b));
+    // ASCII-only: HTTP headers are guaranteed to be ASCII per RFC 7230.
+    // Branchless lowering eliminates libc tolower() locale-aware function call overhead.
+    if (a == b) return true;
+    // XOR of two chars that differ only in case bit (0x20) for A-Z range
+    unsigned char ua = static_cast<unsigned char>(a);
+    unsigned char ub = static_cast<unsigned char>(b);
+    return (ua ^ ub) == 0x20 && ((ua | 0x20) >= 'a') && ((ua | 0x20) <= 'z');
 }
```

**Почему это поможет:**
- `std::tolower(unsigned char)` — libc function call с locale dispatch (не inlineable).
- В compute это **4.30% perf** / **2.33% Ir** (2.2M Ir).
- `ci_char_equal` вызывается из `ci_equal_fast` → `string_to_field` → `get(string_view)`, и из `case_insensitive_less` → binary search по rare headers.
- Новый код: 2 сравнения + 1 XOR + 2 OR — всё inlineable, zero function calls.

**Почему `(a | 0x20) == (b | 0x20)` недостаточно:**
- `(a | 0x20) == (b | 0x20)` даёт ложные positives для символов, отличающихся на bit 0x20, но не являющихся буквами. Например: `'@'` (0x40) и `` '`' `` (0x60) дадут true. Для HTTP headers это безопасно (header names — это tokens, `@` и `` ` `` не являются token chars), но более точный вариант безопаснее.

**Ожидаемый выигрыш:**
- Conservative: +1% compute throughput
- Realistic: +2-3% compute throughput
- Optimistic: +4% compute throughput
- Hello: +0.5-1% (меньше вызовов `ci_char_equal` на hot path)

**Риск регрессий:** Минимальный. HTTP headers — ASCII per RFC 7230 §3.2. Не-ASCII байты уже отклонены parser validation loop (byte >= 0x80 → error). Единственный edge case: если `ci_char_equal` вызывается для произвольных binary data вне HTTP headers — в KATANA это не происходит.

**Тесты после:**
```bash
# perf report: tolower должен исчезнуть из compute top-10
perf report -i perf.data | head -20
# callgrind: Ir для ci_char_equal / ci_equal_fast должен уменьшиться
```

**Критерий успеха:** `tolower` исчезает из `perf report`, `ci_char_equal` Ir уменьшается на ≥50%.

---

### 1.3 Add `[[gnu::always_inline]]` to `skip_ws()` for compact JSON

**Файл:** `serde.hpp` — строка 70

**Функция:** `json_cursor::skip_ws()`

**Что заменить → на что:**

```diff
-    void skip_ws() noexcept {
+    [[gnu::always_inline]] void skip_ws() noexcept {
```

**Почему это поможет:**
- `skip_ws()` вызывается ~164,580 раз за callgrind pass.
- Для compact JSON (без whitespace) функция сразу возвращается: `if (eof() || !is_json_whitespace(...)) return;`.
- Но overhead call/ret (push/pop RBP, etc.) остаётся. Для hot loop вызовов это 2-4 Ir × 164K = ~0.5-0.7M Ir.
- `always_inline` позволит компилятору встроить fast-path check прямо в caller.
- Evidence: 3.68% perf, 1.72% Ir в compute. 44% annotate samples на early-exit check.

**Ожидаемый выигрыш:**
- Conservative: +0.5% compute
- Realistic: +1% compute
- Optimistic: +2% compute

**Риск регрессий:** Нулевой. Это подсказка компилятору, не меняющая семантику. В worst case (компилятор не inline из-за размера) — no-op.

**Тесты после:**
```bash
# callgrind: skip_ws должен исчезнуть как отдельная функция
callgrind_annotate ... | grep skip_ws
# Если исчез — Ir ушёл в caller, суммарный Ir не должен увеличиться
```

**Критерий успеха:** `skip_ws` как отдельный символ исчезает из callgrind output.

---

### Phase 1 Summary

| Fix | File | Effort | Expected Gain | Confidence |
|---|---|---|---|---|
| field enum lookups | `http.cpp:214,278`, `http_server.cpp:418,422` | 5 min | +3-5% both | **High** |
| tolower → branchless | `http_headers.hpp:31-34` | 5 min | +2-3% compute | **High** |
| always_inline skip_ws | `serde.hpp:70` | 1 min | +1% compute | **High** |

**Суммарный ожидаемый выигрыш Phase 1:** +5-8% throughput в обоих сценариях.

**Можно делать параллельно:** Все три правки независимы.

---

## Phase 2: Parser Work — 1-2 часа, Low-Medium Risk

### Цель
Устранить #1 bottleneck: parser validation loop (48% Ir в compute, 24% в hello).

---

### 2.1 Skip body byte validation (HIGH ROI)

**Файл:** `http.cpp` — строки 627-642

**Функция:** `parser::parse_available()`

**Что сейчас:**
```cpp
if (state_ == state::request_line || state_ == state::headers) [[likely]] {
    size_t validation_start = validated_bytes_;
    if (validation_start > 0) {
        --validation_start;
    }
    for (size_t i = validation_start; i < buffer_size_; ++i) {
        uint8_t byte = static_cast<uint8_t>(buffer_[i]);
        if (byte == 0 || byte >= 0x80) [[unlikely]] { ... }
        if (byte == '\n' && (i == 0 || buffer_[i - 1] != '\r')) [[unlikely]] { ... }
    }
    validated_bytes_ = buffer_size_;
}
```

**Проблема:**
- Условие `state_ == request_line || state_ == headers` правильно ограничивает — validation выполняется только в этих состояниях.
- **Но** `validated_bytes_` отслеживает позицию в буфере, а буфер содержит ВСЕ принятые байты, включая начало body (если TCP receive вернул и headers, и часть body в одном read).
- Итог: validation loop сканирует body bytes побайтно, проверяя `byte == 0 || byte >= 0x80` — что бессмысленно для JSON body (может содержать UTF-8 > 0x80).

**Что заменить → на что:**

```diff
 if (state_ == state::request_line || state_ == state::headers) [[likely]] {
     size_t validation_start = validated_bytes_;
     if (validation_start > 0) {
         --validation_start;
     }
-    for (size_t i = validation_start; i < buffer_size_; ++i) {
+    // Only validate header bytes, not body bytes that may be in the buffer.
+    // Body bytes don't need HTTP header validation (they can contain any byte value).
+    // find_header_terminator() looks for \r\n\r\n which marks end of headers.
+    size_t validation_limit = buffer_size_;
+    if (buffer_size_ >= 4) {
+        const char* term = find_header_terminator(buffer_, buffer_size_);
+        if (term) {
+            // Header terminator found: only validate up to end of headers (+4 for \r\n\r\n itself)
+            size_t header_end = static_cast<size_t>(term - buffer_) + 4;
+            if (header_end < validation_limit) {
+                validation_limit = header_end;
+            }
+        }
+    }
+    for (size_t i = validation_start; i < validation_limit; ++i) {
         uint8_t byte = static_cast<uint8_t>(buffer_[i]);
         if (byte == 0 || byte >= 0x80) [[unlikely]] { ... }
         if (byte == '\n' && (i == 0 || buffer_[i - 1] != '\r')) [[unlikely]] { ... }
     }
     validated_bytes_ = buffer_size_;
 }
```

**Почему это поможет:**
- В compute, request body = JSON array of doubles, e.g. `[1.0,2.0,...,10.0]` — десятки-сотни байт.
- Эти байты проходят через validation loop побайтно, хотя body не нуждается в HTTP header validation.
- Parser в compute = **48.03% Ir**. Из annotate: горячие instructions — byte load + compare + branch — доминируют.
- Исключение body bytes из validation сократит количество итераций цикла на ~40-60% для compute (зависит от размера body vs headers).

**Дополнительное improvement** (optional, если `find_header_terminator` сама дорогая):
```cpp
// Alternative: after we transition from headers to body state, set validated_bytes_ to skip rest
// This avoids calling find_header_terminator on every parse_available call
```

**Ожидаемый выигрыш:**
- Conservative: +5% compute throughput, +2% hello
- Realistic: **+10-15% compute**, +3-5% hello
- Optimistic: +20% compute, +5-8% hello

**Риск регрессий:**
- **Low.** Body bytes не нуждаются в HTTP header validation. JSON body может содержать UTF-8 (bytes >= 0x80) и null bytes, что текущий код ошибочно бы отклонил.
- Edge case: `find_header_terminator` вызывается для каждого `parse_available()` — но эта функция уже вызывается на строке 646 в том же методе. Можно кешировать результат.
- Security: не ослабляет header validation — headers всё ещё полностью валидируются.

**Тесты после:**
- E2E hello + compute smoke tests
- Payload с UTF-8 в body (должен проходить, ранее мог ошибочно отклоняться)
- callgrind: Ir `parse_available` в compute должен уменьшиться на 30-50%

**Критерий успеха:** `parse_available` Ir в compute уменьшается с 48% до ≤30%.

---

### 2.2 SIMD validation loop (SSE2) — Deep Refactor, Phase 2 add-on

**Файл:** `http.cpp` — строки 632-640

**Функция:** `parser::parse_available()`, validation inner loop

**Что заменить → на что:**

```cpp
// SSE2: validate 16 bytes at once instead of 1
// Check: byte == 0 || byte >= 0x80 → equivalent to signed byte <= 0
// Also need CRLF consistency check (bare \n without preceding \r)
#ifdef __SSE2__
{
    const uint8_t* buf = reinterpret_cast<const uint8_t*>(buffer_);
    size_t i = validation_start;

    // SIMD: process 16 bytes at a time
    for (; i + 16 <= validation_limit; i += 16) {
        __m128i chunk = _mm_loadu_si128(reinterpret_cast<const __m128i*>(buf + i));
        __m128i zero = _mm_setzero_si128();

        // byte == 0 || byte >= 0x80 ↔ signed byte <= 0
        // _mm_cmpgt_epi8(zero, chunk) catches byte > 0x7F (signed negative)
        // _mm_cmpeq_epi8(chunk, zero) catches byte == 0
        __m128i cmp_zero = _mm_cmpeq_epi8(chunk, zero);
        __m128i cmp_high = _mm_cmpgt_epi8(zero, chunk); // signed: 0 > chunk → chunk < 0 → chunk >= 0x80
        __m128i bad = _mm_or_si128(cmp_zero, cmp_high);
        if (_mm_movemask_epi8(bad) != 0) [[unlikely]] {
            return std::unexpected(make_error_code(error_code::invalid_fd));
        }
    }

    // Scalar tail for remaining bytes
    for (; i < validation_limit; ++i) {
        uint8_t byte = static_cast<uint8_t>(buffer_[i]);
        if (byte == 0 || byte >= 0x80) [[unlikely]] {
            return std::unexpected(make_error_code(error_code::invalid_fd));
        }
        if (byte == '\n' && (i == 0 || buffer_[i - 1] != '\r')) [[unlikely]] {
            return std::unexpected(make_error_code(error_code::invalid_fd));
        }
    }
}
#else
    // Original scalar loop
    for (size_t i = validation_start; i < validation_limit; ++i) { ... }
#endif
```

**Замечание:** CRLF check (`byte == '\n' && prev != '\r'`) сложнее SIMD-ифицировать из-за cross-boundary dependency (нужен предыдущий байт). Два подхода:
1. SIMD только для `byte == 0 || byte >= 0x80`, scalar для CRLF — уже даёт основной выигрыш.
2. Отдельный SIMD pass для `\n` поиска с последующей точечной проверкой `\r` перед каждым найденным `\n`.

**Ожидаемый выигрыш:**
- Conservative: +3% hello throughput
- Realistic: +5-10% hello, +3-5% compute (поверх 2.1)
- Optimistic: +15% hello

**Риск регрессий:** Medium. Boundary handling для SIMD нетривиален. Нужны тесты с payload sizes: 0, 1, 15, 16, 17, 31, 32, 33, MAX.

**Сложность:** Medium-High. Рекомендуется делать **после** 2.1 (skip body validation), т.к. 2.1 уже сокращает объём работы validation loop.

**Строго последовательно после:** Phase 2.1.

**Тесты после:**
- Unit test: validation с payloads разных размеров (0..100), с invalid bytes, с bare LF.
- callgrind: parse_available Ir должен уменьшиться дополнительно.
- wrk: median throughput.

**Критерий успеха:** `parse_available` из 48% → ≤20% Ir в compute (суммарно с 2.1).

---

### Phase 2 Summary

| Fix | File | Effort | Expected Gain | Confidence | Sequential? |
|---|---|---|---|---|---|
| Skip body validation | `http.cpp:627-642` | 30 min | **+10-15% compute** | **High** | Independent |
| SIMD validation | `http.cpp:632-640` | 2-3 hrs | +5-10% hello | Medium | After 2.1 |

**Суммарный ожидаемый выигрыш Phase 2:** +10-20% compute, +5-10% hello.

---

## Phase 3: Serialization Work — 2-3 часа, Medium Risk

### Цель
Устранить #2 bottleneck: response serialization (29% Ir в hello, 10% в compute).

---

### 3.1 Single-pass serialize with pre-computed sizes

**Файл:** `http.cpp` — строки 203-268

**Функция:** `response::serialize_into(std::string&)`

**Что сейчас:** Два прохода по headers (size calc + write), 6+ отдельных append calls.

**Что заменить → на что:**

```cpp
void response::serialize_into(std::string& out) const {
    if (chunked) {
        out = serialize_chunked();
        ::katana::detail::syscall_metrics_registry::instance().note_response_serialize(
            out.size(), 0, out.capacity());
        return;
    }

    // --- Fast path: pre-compute everything in one pass ---
    char status_buf[16];
    auto [status_ptr, status_ec] = std::to_chars(status_buf, status_buf + sizeof(status_buf), status);
    const size_t status_len = static_cast<size_t>(status_ptr - status_buf);

    char content_length_buf[32];
    size_t cl_len = 0;
    bool need_cl = !headers.contains(field::content_length);  // uses fix from 1.1
    if (need_cl) {
        auto [ptr, ec] = std::to_chars(
            content_length_buf, content_length_buf + sizeof(content_length_buf), body.size());
        if (ec == std::errc()) {
            cl_len = static_cast<size_t>(ptr - content_length_buf);
        }
    }

    // Single size calculation
    size_t total = HTTP_VERSION_PREFIX.size() + status_len + 1 + reason.size() + CRLF.size();
    for (const auto& [name, value] : headers) {
        total += name.size() + HEADER_SEPARATOR.size() + value.size() + CRLF.size();
    }
    if (cl_len > 0) {
        total += 14 + HEADER_SEPARATOR.size() + cl_len + CRLF.size(); // "Content-Length: <val>\r\n"
    }
    total += CRLF.size() + body.size();

    const size_t old_capacity = out.capacity();
    out.clear();
    out.reserve(total);

    // Single write pass — no intermediate checks
    out.append(HTTP_VERSION_PREFIX);
    out.append(status_buf, status_len);
    out.push_back(' ');
    out.append(reason);
    out.append(CRLF);

    for (const auto& [name, value] : headers) {
        out.append(name);
        out.append(HEADER_SEPARATOR);
        out.append(value);
        out.append(CRLF);
    }

    if (cl_len > 0) {
        out.append("Content-Length");
        out.append(HEADER_SEPARATOR);
        out.append(content_length_buf, cl_len);
        out.append(CRLF);
    }

    out.append(CRLF);
    out.append(body);
    ::katana::detail::syscall_metrics_registry::instance().note_response_serialize(
        out.size(), old_capacity, out.capacity());
}
```

**Ключевые изменения:**
1. `headers.get("Content-Length")` → `headers.contains(field::content_length)` — from Phase 1.
2. `reserve(total)` with **exact** size instead of estimate — eliminates reallocation.
3. Status buf and content-length buf computed upfront.
4. All `append` calls guaranteed to be no-realloc (since reserved exact size).

**Ожидаемый выигрыш:**
- Conservative: +3% hello
- Realistic: +5-8% hello, +2-3% compute
- Optimistic: +10% hello

**Риск регрессий:** Low. Semantic behavior unchanged. Only thing that changes: exact reserve size, order of Content-Length computation.

**Тесты после:**
- Validate identical wire output: `diff <(curl old) <(curl new)`.
- callgrind: `serialize_into` Ir should decrease by 10-20%.

---

### 3.2 Switch hot path to `io_buffer` serialize (Medium Refactor)

**Файлы:**
- `http.cpp` — строки 328-412: `serialize_into(io_buffer&)` — **уже существует!**
- `http_server.cpp` — строка 440: `resp.serialize_into(state.response_scratch)`

**Что сейчас:**
- Hot path в `handle_connection` использует `std::string` overload: `resp.serialize_into(state.response_scratch)`.
- `io_buffer` overload (lines 328-412) делает single-pass direct-write без `std::string` growth overhead.

**Что заменить → на что:**
- Заменить `state.response_scratch` (std::string) на `io_buffer` в `connection_state`.
- Вызывать `resp.serialize_into(state.response_io_buffer)` вместо string variant.
- Для `active_response.append(state.response_scratch)` — использовать `io_buffer::data()` + `io_buffer::size()`.

**Сложность:** Medium. Требует изменений в `connection_state` struct.

**Ожидаемый выигрыш:**
- Conservative: +5% both
- Realistic: +8-12% hello, +5% compute
- Optimistic: +15% hello

**Риск регрессий:** Medium. Нужно убедиться, что `io_buffer` lifecycle совместим с pipelining.

**Строго последовательно после:** 3.1

**Тесты после:**
- wrk с pipelining: `wrk -t4 -c512 -d10s --latency`.
- Проверка на memory leaks: `valgrind --tool=memcheck`.

---

### 3.3 Pre-built response template for hello-like endpoints (Deep)

**Файлы:**
- `http.cpp` — новая функция `response::serialize_static_into()`
- `router.hpp` / hello server main — fast path для static response

**Идея:**
```cpp
// For responses with fixed status + fixed headers + variable body:
// Pre-compute "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: keep-alive\r\nContent-Length: "
// Then append: itoa(body.size()) + "\r\n\r\n" + body
static constexpr char HELLO_RESPONSE_PREFIX[] =
    "HTTP/1.1 200 OK\r\n"
    "Content-Type: text/plain\r\n"
    "Connection: keep-alive\r\n"
    "Content-Length: ";
// Total prefix = 88 bytes, single memcpy
```

**Сложность:** Medium-High. Нужен механизм для определения "стабильного response shape" и cache invalidation.

**Ожидаемый выигрыш:** +15-25% hello throughput.

**Строго последовательно после:** 3.1, 3.2.

---

### Phase 3 Summary

| Fix | File | Effort | Expected Gain | Confidence | Sequential? |
|---|---|---|---|---|---|
| Single-pass serialize | `http.cpp:203-268` | 1 hr | +5-8% hello | **High** | Independent |
| io_buffer hot path | `http_server.cpp:440` | 2 hrs | +8-12% hello | Medium | After 3.1 |
| Static response template | New | 3-4 hrs | +15-25% hello | Medium | After 3.2 |

**Phase 3 можно делать параллельно с Phase 2.**

---

## Phase 4: Routing/Dispatch Work — 2-3 часа, Low-Medium Risk

### Цель
Уменьшить dispatch overhead: 16% Ir в hello (router), 20.5% Ir в compute (generated dispatch).

---

### 4.1 Switch hello to `fast_router` (Quick Win)

**Файлы:**
- Hello server `main.cpp` (не в этом репозитории, но паттерн из `compute_api/main.cpp`)

**Что заменить → на что:**

Hello server сейчас (предположительно):
```cpp
// Before: uses generic router
katana::http::route_entry routes[] = { ... };
katana::http::router r(routes);
return http::server(r).listen(port).run();
```

Заменить на `fast_router` pattern из compute:
```cpp
// After: uses fast_router with hash-based O(1) dispatch
class hello_fast_router {
public:
    katana::result<void> dispatch_to(const katana::http::request& req,
                                     katana::http::request_context& ctx,
                                     katana::http::response& out) const {
        // Direct dispatch — no path splitting, no segment matching
        if (req.http_method == katana::http::method::get && req.uri == "/") {
            // inline handler
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

**Ожидаемый выигрыш:**
- Conservative: +5% hello
- Realistic: +8-12% hello
- Optimistic: +15% hello

**Риск регрессий:** Нулевой для hello. Compute уже использует fast_router.

**Строго последовательно:** Не зависит от других phases.

---

### 4.2 Optimize generated dispatch — reduce pre-handler tax

**Файл:** `compute_api/generated/generated_router_bindings.hpp` — строки 64-104

**Функция:** `dispatch_compute_sum()`

**Текущий pre-handler cost breakdown** (from callgrind, total 20.51% Ir = 19.6M Ir):
1. Accept header check: `req.headers.get(field::accept)` + comparisons — ~2M Ir
2. Content-Type check: `req.headers.get(field::content_type)` + `ascii_iequals` + `media_type_token` — ~4M Ir
3. JSON body parse: `parse_compute_sum_request(req.body, &ctx.arena)` — ~5M Ir
4. Validation: `validate_compute_sum_request(*parsed_body)` — ~1M Ir
5. Handler context scope: `handler_context::scope context_scope(req, ctx)` — ~0.5M Ir
6. Handler: `handler.compute_sum(*parsed_body, out)` — 5.5M Ir
7. Content-Type fallback: `out.headers.get(field::content_type)` check — ~0.5M Ir

**Optimizations:**

#### 4.2.1 Skip Accept check for single-type endpoints
```diff
 inline katana::result<void> dispatch_compute_sum(...) {
     constexpr std::string_view kJsonContentType = "application/json";
-    auto accept = req.headers.get(katana::http::field::accept);
-    if (accept && !accept->empty() && *accept != "*/*" && *accept != kJsonContentType) {
-        out.assign_error(katana::problem_details::not_acceptable("unsupported Accept header"));
-        return {};
-    }
+    // Fast path: skip Accept check — most clients send */*, empty, or omit.
+    // Only check if Accept header is explicitly set to a non-matching type.
+    if (auto accept = req.headers.get(katana::http::field::accept);
+        accept && !accept->empty()) [[unlikely]] {
+        if (*accept != "*/*" && *accept != kJsonContentType) {
+            out.assign_error(katana::problem_details::not_acceptable("unsupported Accept header"));
+            return {};
+        }
+    }
```

#### 4.2.2 Skip post-handler Content-Type fallback when handler already sets it
```diff
-    if (out.status != 204 && !out.body.empty() &&
-        !out.headers.get(katana::http::field::content_type)) {
-        out.set_header("Content-Type", kJsonContentType);
-    }
+    // Handler already sets Content-Type via out.set_header(field::content_type, "application/json")
+    // Skip redundant check for endpoints that always set it.
+    if (out.status != 204 && !out.body.empty() &&
+        !out.headers.contains(katana::http::field::content_type)) {
+        out.set_header(katana::http::field::content_type, kJsonContentType);
+    }
```

Note: line 101 uses `out.set_header("Content-Type", kJsonContentType)` — string overload. Change to enum:
```diff
-        out.set_header("Content-Type", kJsonContentType);
+        out.set_header(katana::http::field::content_type, kJsonContentType);
```

#### 4.2.3 Use `ascii_iequals` branchless variant for Content-Type
(This benefits from Phase 1.2 tolower fix propagating to `ascii_iequals`.)

**Ожидаемый выигрыш:**
- Conservative: +2% compute
- Realistic: +3-5% compute
- Optimistic: +8% compute

**Риск регрессий:** Low. Accept check optimization only changes branch prediction hint. Content-Type fallback fix is a pure optimization.

**Тесты после:**
- E2E test: POST /compute/sum with `Accept: application/xml` → 406.
- E2E test: POST /compute/sum with `Accept: */*` → 200.
- callgrind: `dispatch_compute_sum` Ir should decrease by 10-20%.

**Критерий успеха:** `dispatch_compute_sum` Ir decreases from 20.51% to ≤17%.

---

### 4.3 katana_gen: codegen improvements for dispatch templates

**Файлы:** `katana_gen/` — generator that produces `generated_router_bindings.hpp`

**Идея:** Modify the code generator to emit optimized dispatch for single-content-type endpoints:
- Skip Accept check entirely if only `application/json` is produced.
- Skip Content-Type validation if endpoint always expects `application/json`.
- Pre-compute `has_body` flag at compile time from OpenAPI spec.

**Сложность:** Medium. Requires changes to code generator, not just generated code.

**Строго последовательно после:** 4.2 (first validate manual fixes, then automate in codegen).

---

### Phase 4 Summary

| Fix | File | Effort | Expected Gain | Confidence | Sequential? |
|---|---|---|---|---|---|
| Hello fast_router | hello server main | 30 min | +8-12% hello | **High** | Independent |
| Dispatch optimization | `generated_router_bindings.hpp:64-104` | 1 hr | +3-5% compute | **High** | Independent |
| Codegen improvements | `katana_gen/` | 3-4 hrs | +3-5% compute (future) | Medium | After 4.2 |

**Phase 4 можно делать параллельно с Phases 2 и 3.**

---

## Phase 5: Deeper Refactors — 1-2 дня, Medium-High Risk

### 5.1 SIMD parser validation (if still needed after Phase 2.1)
- See Phase 2.2 above.

### 5.2 Zero-copy response path (writev from prebuilt buffers)
- Skip all `std::string` serialization.
- Use `writev()` with prebuilt iovec: `[header_prefix, content_length_str, header_suffix, body]`.
- Eliminates all `append` and `memcpy` from serialize path.
- **Effort:** 4-8 hrs. **Risk:** High. Needs careful integration with pipelining/batching.

### 5.3 Compile-time route table with constexpr hashing
- Generate `constexpr` perfect hash at compile time.
- Route dispatch = single hash + switch, zero-runtime string comparisons.
- **Effort:** 4-6 hrs. **Risk:** Medium. Compute already has `fast_router` with runtime hash.

### 5.4 Custom JSON parser for compute (skip generic serde)
- For `compute_sum_request` (array of doubles), write a specialized parser:
  ```cpp
  // Skip serde::json_cursor entirely
  // Direct: scan for '[', then parse doubles inline with std::from_chars
  const char* p = body.data() + 1; // skip '['
  while (*p != ']') {
      double val;
      auto [next, ec] = std::from_chars(p, body.data() + body.size(), val);
      result.push_back(val);
      p = next;
      if (*p == ',') ++p;
  }
  ```
- **Effort:** 2 hrs. **Risk:** Medium. Must handle edge cases (whitespace, empty arrays, errors).
- **Expected gain:** -30% generated dispatch Ir (eliminates skip_ws, try_array_start, try_comma overhead).

### 5.5 Avoid memmove in `prepare_for_next_request`
- **File:** `http.cpp:1152-1159`
- When `parse_pos_ >= buffer_size_` (all data consumed), skip memmove:
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
- **Effort:** 5 min. **Risk:** None.
- **Expected gain:** +0.5-1% both (2.80% Ir in hello for prepare_for_next_request).

---

## Final Rollout Order

```
┌──────────────────────────────────────────────────────────┐
│                        Day 1                              │
├──────────────────────────────────────────────────────────┤
│  Phase 1.1: field enum lookups         (5 min, +3-5%)    │
│  Phase 1.2: tolower → branchless       (5 min, +2-3%)    │
│  Phase 1.3: always_inline skip_ws      (1 min, +1%)      │
│  Phase 5.5: prepare_for_next memmove   (5 min, +0.5%)    │
│                                                           │
│  → Verify: wrk + callgrind baseline comparison            │
│  → Expected total Day 1: +5-8% both                      │
├──────────────────────────────────────────────────────────┤
│                        Day 2                              │
├──────────────────────────────────────────────────────────┤
│  Phase 2.1: Skip body validation       (30 min, +10-15%) │
│  Phase 3.1: Single-pass serialize      (1 hr, +5-8%)     │
│  Phase 4.2: Generated dispatch opt     (1 hr, +3-5%)     │
│                                                           │
│  → Verify: wrk + callgrind                                │
│  → Expected total Day 1+2: +15-25% both                  │
├──────────────────────────────────────────────────────────┤
│                        Day 3                              │
├──────────────────────────────────────────────────────────┤
│  Phase 4.1: Hello fast_router          (30 min, +8-12%)  │
│  Phase 3.2: io_buffer serialize path   (2 hrs, +8-12%)   │
│                                                           │
│  → Verify: wrk + callgrind                                │
│  → Expected total Day 1-3: +20-35% both                  │
├──────────────────────────────────────────────────────────┤
│                      Week 2+                              │
├──────────────────────────────────────────────────────────┤
│  Phase 2.2: SIMD validation            (if still needed) │
│  Phase 3.3: Static response template   (hello focused)   │
│  Phase 5.2: writev zero-copy response                    │
│  Phase 5.4: Custom JSON parser                           │
│  Phase 4.3: Codegen improvements                         │
└──────────────────────────────────────────────────────────┘
```

---

## Параллельность

### Можно делать параллельно:
- Phase 1 (все три fix) — полностью независимы друг от друга
- Phase 2 (parser) и Phase 3 (serialization) — разные файлы, разные функции
- Phase 2 (parser) и Phase 4 (routing) — разные файлы
- Phase 3 (serialization) и Phase 4 (routing) — разные файлы (кроме 3.2 → http_server.cpp)

### Строго последовательно:
- Phase 2.2 (SIMD) → после Phase 2.1 (skip body validation) — иначе SIMD-ифицируем лишние байты
- Phase 3.2 (io_buffer) → после Phase 3.1 (single-pass serialize) — нужен стабильный serialize API
- Phase 3.3 (static template) → после Phase 3.2 (io_buffer) — строится поверх нового serialize path
- Phase 4.3 (codegen) → после Phase 4.2 (manual dispatch fix) — сначала валидируем, потом автоматизируем

---

## Оценка надёжности рекомендаций

### Самые надёжные (High Confidence)

1. **field enum lookups (1.1)** — Zero-risk, API уже существует, evidence прямой: string_to_field исчезнет из hot path.
2. **tolower → branchless (1.2)** — Zero-risk для HTTP context, evidence: 4.30% perf на single libc function.
3. **Skip body validation (2.1)** — Логически обоснованно: body bytes не нуждаются в header validation. Evidence: 48% Ir.
4. **Hello fast_router (4.1)** — Compute уже использует, zero-risk pattern copy.

### Потенциально спорные (требуют верификации)

1. **SIMD validation (2.2)** — Выигрыш зависит от среднего размера headers. Для очень коротких запросов (GET /) overhead SIMD setup может нивелировать выигрыш. В VirtualBox SIMD timing может отличаться от bare metal.
2. **io_buffer serialize (3.2)** — `io_buffer` overload уже существует в коде, но не используется на hot path. Возможно есть причина (bug, API mismatch). Нужно проверить.
3. **Static response template (3.3)** — Предполагает стабильный response shape. Если middleware добавляет dynamic headers, template invalidируется.

### Красивый microbenchmark win, но спорный E2E win

1. **always_inline skip_ws (1.3)** — Microbenchmark покажет -1%, но в E2E wrk может быть в пределах noise (VirtualBox variance ~10%).
2. **prepare_for_next memmove (5.5)** — 2.80% Ir, но в E2E это <1% throughput impact из-за memmove efficiency для small sizes.
3. **Custom JSON parser (5.4)** — Microbenchmark для JSON parsing покажет 3x improvement, но в E2E доля JSON parsing = 1.72% → realistically +0.5-1% throughput.
4. **Accept check skip (4.2.1)** — Branch prediction already handles this well. Change improves Ir but not necessarily wallclock.

---

## Итоговая таблица: ROI × Confidence

| Rank | Fix | ROI | Confidence | Effort |
|---|---|---|---|---|
| 1 | Skip body validation (2.1) | **Highest** | High | 30 min |
| 2 | field enum lookups (1.1) | High | High | 5 min |
| 3 | tolower → branchless (1.2) | Medium-High | High | 5 min |
| 4 | Hello fast_router (4.1) | High (hello) | High | 30 min |
| 5 | Single-pass serialize (3.1) | Medium | High | 1 hr |
| 6 | Generated dispatch opt (4.2) | Medium | High | 1 hr |
| 7 | io_buffer serialize (3.2) | High | Medium | 2 hrs |
| 8 | SIMD validation (2.2) | Medium | Medium | 3 hrs |
| 9 | Static response template (3.3) | High (hello) | Medium | 4 hrs |
| 10 | Custom JSON parser (5.4) | Low | Medium | 2 hrs |
