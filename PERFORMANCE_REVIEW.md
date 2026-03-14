# KATANA Performance Review

## Raздел 1. Executive Summary

### 10 главных выводов

1. **Parser `parse_available()` — самый дорогой компонент**: 23.60% Ir в hello, **48.03% Ir** в compute. Байтовый валидационный цикл (`byte == 0 || byte >= 0x80`) сканирует каждый байт поштучно, включая тело запроса в compute — это главный bottleneck.

2. **Response serialization — первый bottleneck в hello**: `serialize_into()` занимает **29.22% Ir** в hello и 10.28% Ir в compute. Каждый ответ проходит через header lookup, итерацию по headers, множественные `std::string::append` и `memcpy`.

3. **Router dispatch не бесплатен даже для hello-world**: `dispatch_with_info()` — **15.97% Ir** в hello. Для единственного маршрута это чрезмерно: generic two-phase dispatch с path splitting, segment matching, specificity scoring.

4. **Generated dispatch дороже, чем compute_sum()**: `dispatch_compute_sum()` — **20.51% Ir** в compute, а сам `compute_sum()` — только **5.76% Ir**. Dispatch несёт Accept gating, Content-Type validation, JSON body parsing, handler context scope.

5. **Header lookup и string_to_field видны в обоих сценариях**: `headers_map::get()` + `string_to_field()` суммарно: hello — **19.13% Ir**, compute — **8.72% Ir**. `string_to_field` вызывает `ci_equal_fast` через bucket + binary search по rare headers.

6. **`tolower` в libc** появляется в compute на **4.30% perf** / 2.33% Ir из-за case-insensitive media-type/header сравнений. Это вызвано `ci_char_equal` через `std::tolower(unsigned char)` в fallback ветках.

7. **JSON `skip_ws()` видна в compute**: 3.68% perf, 1.72% Ir. Annotate показывает, что 44% времени уходит на early-exit check `cmpb $0x0,(%rdi,%rcx,1)` → `je` (fast path no-whitespace). Вызывается ~164,580 раз за callgrind pass.

8. **Framework floor высокий**: даже для hello-world, framework overhead (parser + serializer + router + headers) составляет **>75%** instruction budget. Endpoint-логика минимальна.

9. **Compute не медленнее из-за математики**: 22.4% throughput drop hello→compute обусловлен: (a) parser обрабатывает тело запроса (+doubles array), (b) generated dispatch overhead, (c) JSON parsing, (d) media-type checks.

10. **Shared floor vs compute-specific**: ~60% overhead общий (parser, serializer, headers), ~40% compute-specific (generated dispatch, JSON, tolower).

### Shared framework overhead vs compute-specific

| Компонент | Hello Ir% | Compute Ir% | Тип |
|---|---:|---:|---|
| `parse_available()` | 23.60% | 48.03% | Shared (но значительно хуже в compute из-за body) |
| `serialize_into()` | 29.22% | 10.28% | Shared |
| `dispatch_with_info()` | 15.97% | — | Hello-only (compute использует fast_router) |
| `headers_map::get()` | 11.72% | 4.21% | Shared |
| `string_to_field()` | 7.41% | 4.51% | Shared |
| `dispatch_compute_sum()` | — | 20.51% | Compute-only |
| `compute_sum()` | — | 5.76% | Compute-only |
| `skip_ws()` | — | 1.72% | Compute-only |
| `tolower` (libc) | — | 2.33% | Compute-only |

---

## Раздел 2. Ranked Bottlenecks

### Rank 1: Parser validation loop — `parse_available()`

- **Component**: `katana::http::parser::parse_available()`, validation loop lines 632-641 in `http.cpp`
- **Evidence perf**: hello 16.40%, compute **31.67%**
- **Evidence callgrind**: hello 51.6M Ir (23.60%), compute 45.9M Ir (**48.03%**)
- **Annotate hotspot**: `test %sil,%sil` (19.06%) + `jle` (20.79%) + `cmp $0xa,%sil` (6.68%) in compute annotate
- **Why it matters**: Сканирует **каждый** байт буфера (включая body для compute) побайтно, проверяя `byte == 0 || byte >= 0x80` и CRLF-consistency. Это O(N) от размера запроса. В compute body содержит JSON array doubles, что удваивает объём валидации vs hello.
- **Affected scenarios**: **both** (значительно хуже в compute)

### Rank 2: Response serialization — `serialize_into()`

- **Component**: `katana::http::response::serialize_into(std::string&)`, lines 203-268 in `http.cpp`
- **Evidence perf**: hello 9.36%, compute 5.90%
- **Evidence callgrind**: hello **63.9M Ir (29.22%)**, compute 9.8M Ir (10.28%)
- **Callgrind breakdown**: `string::append` — 7.98M Ir, `push_back` — 1.29M Ir, `reserve` — 0.85M Ir, header iteration — 14.9M Ir
- **Why it matters**: Каждый ответ: (1) lookup `Content-Length` header через `string_to_field`, (2) итерация всех headers для расчёта размера, (3) `reserve`, (4) повторная итерация для записи, (5) множественные `append`. Это 6+ calls к `append` даже для минимального ответа.
- **Affected scenarios**: **both** (доминирует в hello)

### Rank 3: Router dispatch — `dispatch_with_info()`

- **Component**: `katana::http::router::dispatch_with_info()`, lines 336-410 in `router.hpp`
- **Evidence perf**: hello 11.85%
- **Evidence callgrind**: hello 34.9M Ir (**15.97%**)
- **Why it matters**: Для 1 маршрута: `strip_query` → `split_path` (loop) → loop over `routes_` → `match_segments` → `specificity_score`. Всё это для одного GET `/`. Hello использует generic `router`, compute использует `fast_router` с hash dispatch, поэтому в compute этот overhead минимален.
- **Affected scenarios**: **hello** (и любой сервис без `fast_router`)

### Rank 4: Generated dispatch overhead — `dispatch_compute_sum()`

- **Component**: `generated::dispatch_compute_sum()`, lines 64-104 in `generated_router_bindings.hpp`
- **Evidence perf**: compute 8.20%
- **Evidence callgrind**: compute **19.6M Ir (20.51%)**, из которых `compute_sum` = 5.5M Ir
- **Pre-handler tax breakdown**: Accept header check (get + compare), Content-Type check (get + `ascii_iequals` + `media_type_token`), JSON body parse (`parse_compute_sum_request`), validation (`validate_compute_sum_request`), context scope setup
- **Why it matters**: ~14M Ir overhead перед вызовом handler. Dispatch дороже handler в **3.5x**.
- **Affected scenarios**: **compute** (и все generated endpoints)

### Rank 5: Header lookup + field normalization

- **Component**: `headers_map::get(string_view)` + `string_to_field()`
- **Evidence perf**: hello: `string_to_field` 6.00%, compute: `string_to_field` 4.26%, `tolower` 4.30%
- **Evidence callgrind**: hello: `get()` 25.6M Ir (11.72%), `string_to_field` 16.2M Ir (7.41%). Compute: `get()` 4.0M Ir, `string_to_field` 4.3M Ir
- **Why it matters**: `get(string_view)` каждый раз вызывает `string_to_field()` → hash → bucket scan с `ci_equal_fast` → если не найдено: binary search в 342-element rare headers. Plus `headers.get("Content-Length")` и `headers.get("Connection")` в serialize/handle_connection используют string-view overload вместо field enum.
- **Affected scenarios**: **both**

### Rank 6: JSON whitespace — `skip_ws()`

- **Component**: `katana::serde::json_cursor::skip_ws()`, lines 70-138 in `serde.hpp`
- **Evidence perf**: compute 3.68%
- **Evidence callgrind**: 1.65M Ir, ~164,580 вызовов
- **Annotate**: 44% samples на `cmpb $0x0,(%rdi,%rcx,1)` → `je` (no-whitespace early exit)
- **Why it matters**: Вызывается на каждый JSON token. Для compact JSON (`[1.0,2.0,3.0,...]`) whitespace отсутствует, но overhead вызова и early-exit check остаётся. SIMD path не используется (whitespace runs < 8 chars).
- **Affected scenarios**: **compute**

### Rank 7: `prepare_for_next_request()` + arena reset

- **Component**: `parser::prepare_for_next_request()`, line 1152 in `http.cpp`
- **Evidence perf**: hello 4.03%
- **Evidence callgrind**: hello 6.1M Ir (2.80%)
- **Why it matters**: `memmove` remaining bytes, full `reset_message_state` including `headers.reset()`. При pipelining вызывается на каждый запрос.
- **Affected scenarios**: **both**

---

## Раздел 3. Prioritized Fix Plan

| # | What to change | Files/Functions | Difficulty | Conservative | Realistic | Optimistic | Affects | Confidence |
|---|---|---|---|---|---|---|---|---|
| 1 | SIMD-ify parser validation loop или skip body validation | `http.cpp:632-641` `parse_available()` | Medium | +5% throughput | +10-15% throughput | +20% throughput | Throughput, p50, p99, CPU — **both** | **High** |
| 2 | Pre-format response template for stable shapes (hello) | `http.cpp:203-268` `serialize_into()` | Medium | +5% hello throughput | +10-15% hello | +20% hello | Throughput, p50, CPU — **hello primarily** | **High** |
| 3 | Use `field` enum in serialize_into + handle_connection instead of string lookups | `http.cpp:214`, `http_server.cpp:418,422` | **Low** | +2% throughput | +5% throughput | +8% throughput | Throughput, CPU — **both** | **High** |
| 4 | Add single-route / static fast path to hello server | `router.hpp:336`, hello server main | Low-Medium | +3% hello | +8% hello | +12% hello | Throughput, p50 — **hello** | **High** |
| 5 | Inline Accept/Content-Type checks in generated dispatch | `generated_router_bindings.hpp:64-104` | Medium | +3% compute | +5-8% compute | +12% compute | Throughput, p50 — **compute** | **Medium** |
| 6 | Avoid `std::tolower(unsigned char)` — use `|0x20` bitmask in ci_equal fallback | `http_headers.hpp:31-34` `ci_char_equal()` | **Low** | +1% compute | +2-3% compute | +4% compute | CPU — **compute** | **High** |
| 7 | Fuse skip_ws into token parsing / remove standalone calls for compact JSON | `serde.hpp:70-138` | Medium | +1% compute | +2% compute | +4% compute | Throughput — **compute** | **Medium** |
| 8 | Skip body byte validation in parser (body is not HTTP headers) | `http.cpp:627-641` | Low | +5% compute | +10% compute | +15% compute | Throughput, p50, p99 — **compute** | **High** |
| 9 | Cache `string_to_field` result or switch all hot-path calls to `field` enum | `http_field.cpp:501-527`, `http_headers.hpp:375-386` | Low-Medium | +2% both | +3-5% both | +7% both | CPU — **both** | **High** |
| 10 | Direct-write serialize (bypass `std::string` for io_buffer path) | `http.cpp:328-412` already exists! Switch hot path to use it | Medium | +5% both | +10% both | +15% both | Throughput, p50, CPU — **both** | **Medium** |

---

## Раздел 4. Concrete Code-Level Recommendations

### 4.1 Parser validation loop — SIMD or skip body

**Что сейчас** (http.cpp:627-641):
```cpp
if (state_ == state::request_line || state_ == state::headers) [[likely]] {
    for (size_t i = validation_start; i < buffer_size_; ++i) {
        uint8_t byte = static_cast<uint8_t>(buffer_[i]);
        if (byte == 0 || byte >= 0x80) [[unlikely]] { ... }
        if (byte == '\n' && (i == 0 || buffer_[i - 1] != '\r')) [[unlikely]] { ... }
    }
}
```

**Проблема**: Сканирует весь буфер (включая тело), побайтно. В compute body — JSON array doubles, десятки-сотни байт, которые сканируются напрасно: тело не нуждается в HTTP header validation.

**Рекомендация 1 (Quick win, высокий ROI)**: Ограничить валидационный цикл только заголовочной частью:
```cpp
// Only validate header bytes, not body bytes
size_t validation_limit = buffer_size_;
if (state_ == state::headers) {
    const char* term = find_header_terminator(buffer_, buffer_size_);
    if (term) validation_limit = static_cast<size_t>(term - buffer_) + 4;
}
for (size_t i = validation_start; i < validation_limit; ++i) { ... }
```

**Рекомендация 2 (SIMD acceleration)**: Заменить побайтовый цикл на SSE2/AVX2 range check:
```cpp
// SSE2: check 16 bytes at once for byte == 0 || byte >= 0x80
__m128i chunk = _mm_loadu_si128(ptr);
__m128i zero = _mm_setzero_si128();
__m128i cmp_zero = _mm_cmpeq_epi8(chunk, zero);
__m128i cmp_high = _mm_cmpgt_epi8(zero, chunk); // signed compare catches >= 0x80
__m128i bad = _mm_or_si128(cmp_zero, cmp_high);
if (_mm_movemask_epi8(bad) != 0) { /* found invalid byte */ }
```

**Как измерить**: Сравнить `perf stat` CPU-clock и `wrk` throughput для compute-canonical до и после. Ожидаемый выигрыш: **10-15% throughput** в compute, **3-5%** в hello.

### 4.2 Response serialization — template caching

**Что сейчас** (http.cpp:203-268):
- `headers.get("Content-Length")` — string lookup через `string_to_field` на каждый ответ
- Двойной проход по headers: первый для расчёта размера, второй для записи
- Множественные `append` вызовы (status line, each header, separators, CRLF)

**Рекомендация 1 (Quick win)**: Заменить `headers.get("Content-Length")` на `headers.get(field::content_length)`:
```cpp
// Before:
bool has_content_length = headers.get("Content-Length").has_value();
// After:
bool has_content_length = headers.get(field::content_length).has_value();
```
Экономия: ~400 Ir на вызов × 40K вызовов = ~16M Ir.

**Рекомендация 2 (Medium refactor)**: Для стабильных response shapes (200 OK, 1 header), pre-compute template:
```cpp
// Pre-built template for "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
static constexpr char prefix[] = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                                  "Content-Length: ";
// Single memcpy + itoa + body append
```

**Рекомендация 3**: Уже есть `serialize_into(io_buffer&)` с zero-copy single-pass write (lines 328-412). Переключить hot path в `handle_connection` на `io_buffer` вариант вместо `std::string` варианта.

**Как измерить**: callgrind instruction count для `serialize_into`. Ожидаемый выигрыш: **10-20%** в hello.

### 4.3 Fix string-based header lookups in handle_connection

**Что сейчас** (http_server.cpp:418-425):
```cpp
auto connection_header = req.headers.get("Connection");   // string lookup!
// ...
if (!resp.headers.get("Connection")) {                     // string lookup!
```

**Рекомендация**: Заменить на enum-based lookups:
```cpp
auto connection_header = req.headers.get(http::field::connection);
if (!resp.headers.get(http::field::connection)) {
```

Каждый вызов `get(string_view)` → `string_to_field()` → hash + bucket scan + `ci_equal_fast`. Вызов `get(field)` — прямой linear scan по known_inline_ (16 entries max), без hashing и string comparison.

**Аналогично в serialize_into** (http.cpp:214):
```cpp
// Before:
bool has_content_length = headers.get("Content-Length").has_value();
// After:
bool has_content_length = headers.contains(field::content_length);
```

**Как измерить**: diff callgrind Ir для `string_to_field`. Ожидаемый выигрыш: **3-5%** в both.

### 4.4 tolower elimination

**Что сейчас** (http_headers.hpp:31-34):
```cpp
inline bool ci_char_equal(char a, char b) noexcept {
    return std::tolower(static_cast<unsigned char>(a)) ==
           std::tolower(static_cast<unsigned char>(b));
}
```

`std::tolower` — libc function call с locale checks. В compute это **4.30% perf** / 2.33% Ir.

**Рекомендация**: Заменить на branchless ASCII-only lowering:
```cpp
inline bool ci_char_equal(char a, char b) noexcept {
    // ASCII-only: HTTP headers guaranteed to be ASCII
    return (a | 0x20) == (b | 0x20);
}
```

Или более точно (только A-Z):
```cpp
inline bool ci_char_equal(char a, char b) noexcept {
    if (a == b) return true;
    unsigned char ua = static_cast<unsigned char>(a);
    unsigned char ub = static_cast<unsigned char>(b);
    return (ua ^ ub) == 0x20 && ((ua | 0x20) >= 'a') && ((ua | 0x20) <= 'z');
}
```

**Как измерить**: `perf report` — `tolower` должен исчезнуть. Ожидаемый выигрыш: **2-3%** в compute.

### 4.5 Skip body validation in parser

**Ключевое наблюдение**: validation loop (`byte == 0 || byte >= 0x80`, CRLF check) нужен только для request line и headers. Body может содержать произвольные байты (JSON, binary). Текущий код ограничен условием `state_ == state::request_line || state_ == state::headers`, **но** `validated_bytes_` не сбрасывается при переходе к body parsing, и loop сканирует весь `buffer_size_`.

Фактически, если headers ещё не полностью получены (partial receive), валидация проходит по всем байтам в буфере — включая начало body, если оно уже подгружено.

**Рекомендация**: После обнаружения конца headers (empty line `\r\n\r\n`), установить `validated_bytes_ = buffer_size_` чтобы не ре-валидировать body bytes.

```cpp
if (state_ == state::request_line || state_ == state::headers) [[likely]] {
    // Only validate up to what we know is header area
    size_t max_validate = buffer_size_;
    // If we've found the header terminator, don't validate past it
    for (size_t i = validation_start; i < max_validate; ++i) {
        // ... validation ...
    }
    validated_bytes_ = max_validate;
}
```

Это **самый высокоROI fix для compute**: parser в compute тратит **48% Ir** и значительная часть — на body bytes.

---

## Раздел 5. Optimization Options by Area

### 5.1 Parser

| Вариант | Сложность | Выигрыш | Описание |
|---|---|---|---|
| Skip body validation | Low | **High** | Не валидировать body bytes (только headers нуждаются в HTTP validation) |
| SIMD validation (SSE2/AVX2) | Medium | High | Проверять 16/32 байта за раз вместо 1 |
| Fuse CRLF search with validation | Medium | Medium | Объединить `find_crlf` + validation в один проход |
| Incremental validation (avoid re-scan) | Low | Medium | Убедиться что `validated_bytes_` корректно предотвращает re-scan |

### 5.2 Response serialization

| Вариант | Сложность | Выигрыш | Описание |
|---|---|---|---|
| Use `field` enum instead of string for Content-Length lookup | **Low** | Medium | `headers.get(field::content_length)` vs `headers.get("Content-Length")` |
| Switch hot path to `io_buffer` overload | Medium | High | `serialize_into(io_buffer&)` уже реализован с zero-copy single-pass write |
| Pre-built response template for common shapes | Medium | High (hello) | Один memcpy для status line + fixed headers |
| Avoid double-pass over headers (size calc + write) | Medium | Medium | Рассчитывать размер инкрементально при добавлении headers |
| Replace `push_back(' ')` with merged append | **Low** | Low | Merge status code + space + reason into single append |

### 5.3 Router dispatch

| Вариант | Сложность | Выигрыш | Описание |
|---|---|---|---|
| Use `fast_router` для hello (hash dispatch) | **Low** | High (hello) | Hello сейчас использует generic `router`, compute уже на `fast_router` |
| Single-route specialization | Low | Medium (hello) | Если 1 route — skip split_path, skip loop, direct match |
| Compile-time route table switch | High (arch) | High | `constexpr` route hash table, zero-runtime dispatch |

### 5.4 Header lookup / string_to_field

| Вариант | Сложность | Выигрыш | Описание |
|---|---|---|---|
| Replace all hot-path `get(string_view)` → `get(field)` | **Low** | Medium | Eliminate `string_to_field` calls from serialize/handle_connection |
| Perfect hash for popular headers (replace bucket scan) | Medium | Medium | Eliminate `ci_equal_fast` comparison in bucket scan |
| Replace `ci_char_equal` tolower with `|0x20` | **Low** | Medium (compute) | Eliminate libc `tolower` calls |
| Cache `string_to_field` in parser during header parse | Low | Low | Already partially done for Host/Content-Length |

### 5.5 Generated compute dispatch

| Вариант | Сложность | Выигрыш | Описание |
|---|---|---|---|
| Skip Accept check when only JSON supported | **Low** | Low | Most clients send `*/*` or omit Accept |
| Move Content-Type check to parser level | Medium | Medium | Validate once, not per-route |
| Pre-compute parsed body type tag | Medium | Medium | Avoid repeated type inspection |
| Specialize generated code for single-body-type endpoints | High | Medium | Eliminate generic dispatch branches |

### 5.6 JSON parsing / skip_ws

| Вариант | Сложность | Выигрыш | Описание |
|---|---|---|---|
| Inline `skip_ws` as `[[gnu::always_inline]]` | **Low** | Low-Medium | Eliminate function call overhead for compact JSON |
| Fuse skip_ws into `consume()` / `try_*` as fast-path check | Medium | Medium | `if (*ptr != expected) { skip_ws(); if (*ptr != expected) return false; }` |
| Use `__builtin_expect` for no-whitespace case | **Low** | Low | Already has fast path but compiler may not predict well |

### 5.7 Memory / buffering

| Вариант | Сложность | Выигрыш | Описание |
|---|---|---|---|
| Avoid memmove in `prepare_for_next_request` when possible | Low | Low | If parse_pos == buffer_size, just reset counters |
| Pool response strings across requests | Medium | Medium | Reuse `std::string` allocation across pipeline |
| Pre-allocate exact response size | Low | Low | Already done via `reserve`, but estimate can be tighter |

### 5.8 Specialization for trivial endpoints

| Вариант | Сложность | Выигрыш | Описание |
|---|---|---|---|
| Static response cache for hello-world | Medium | **Very High** (hello) | Pre-serialize entire response, just memcpy to socket |
| Zero-copy response path (writev from prebuilt buffers) | High | Very High | Skip all serialization, write prebuilt iovec |
| Compile-time response template for GET-only routes | High (arch) | Very High | Handler returns content-only, framework adds pre-built envelope |

---

## Раздел 6. Expected Wins

### Если внедрить только top-1 (Parser body validation skip + SIMD)

- **Hello**: +5-8% throughput, p99 улучшение на 5-10%
- **Compute**: **+10-20% throughput**, p99 улучшение на 15-25%
- **Rationale**: Parser — 48% Ir в compute. Устранение валидации body bytes и/или SIMD-ификация даст пропорциональный выигрыш.

### Если внедрить top-3 (Parser + Serializer enum fix + tolower fix)

- **Hello**: +10-15% throughput
- **Compute**: +15-25% throughput
- **Rationale**: Суммарный Ir coverage: parser (48%) + serialize header fix (-5%) + tolower fix (-4%) → ~57% budget touched.

### Если внедрить top-5 (+ Router fast path + generated dispatch optimization)

- **Hello**: **+15-25% throughput**
- **Compute**: **+20-30% throughput**
- **Rationale**: Router dispatch 16% hello Ir eliminated. Generated dispatch 20% compute Ir reduced by ~30%.

### Если глубокий architectural pass (static response cache, io_buffer path, compile-time routing)

- **Hello**: **+30-50% throughput** (approaching wire-rate limited)
- **Compute**: **+25-40% throughput**
- **Rationale**: Static response path для hello может довести throughput к ~2M req/s. io_buffer zero-copy eliminates std::string overhead entirely.

---

## Раздел 7. Validation Plan

### Для каждого изменения:

**Метрики для сравнения:**
1. `wrk -t4 -c512 -d10s` — throughput (req/s), p50, p95, p99, p999
2. `perf stat -e cpu-clock:u,task-clock:u,context-switches,cpu-migrations` — CPU utilization
3. `callgrind` reduced pass — instruction count per function (deterministic!)
4. `perf report` — symbol overhead %

**Артефакты для переснятия:**
- `perf_stat.csv`, `wrk_output.txt` — для throughput/latency
- `callgrind_annotate.txt` — для instruction-level regression check
- `perf_report.txt` + annotate для modified symbols

**Как избежать ложных выводов из-за VirtualBox / отсутствия PMU:**
1. **Используй callgrind как primary metric**: он детерминистичен и не зависит от VM scheduling jitter
2. **Запускай wrk 3+ раз**, бери median: VM может показать 20% variance между прогонами
3. **Не делай выводов по perf stat IPC/branch-miss**: PMU hardware events недоступны в этой VM
4. **Сравнивай callgrind Ir delta по конкретным функциям**, а не суммарный throughput: wrk throughput во VM может быть нестабилен
5. **Контролируй другие нагрузки на хост**: VirtualBox может страдать от host CPU contention

### Validation protocol per change:

```
1. git stash (baseline)
2. Run: wrk -t4 -c512 -d10s × 3 → median
3. Run: callgrind reduced pass
4. Run: perf stat
5. git stash pop (with change)
6. Repeat steps 2-4
7. Compare callgrind Ir for affected functions
8. Compare wrk median throughput
9. If Ir improved but throughput didn't → measurement noise, trust callgrind
```

---

## Раздел 8. Fast Wins vs Deep Refactors

### Quick Wins (< 1 hour, Low risk)

1. **Replace `headers.get("Content-Length")` → `headers.get(field::content_length)`** in serialize_into and handle_connection
   - Files: `http.cpp:214`, `http_server.cpp:418,422`
   - Risk: Zero. API already exists.
   - Expected: -3-5% Ir for serialize + handle_connection

2. **Replace `ci_char_equal` tolower with `|0x20` bitmask**
   - File: `http_headers.hpp:31-34`
   - Risk: Minimal. HTTP headers are ASCII-only by spec.
   - Expected: -2-3% compute perf

3. **Add `[[gnu::always_inline]]` to `skip_ws()` or make it a simple 2-line inline**
   - File: `serde.hpp:70`
   - Risk: None. Already inline, but compiler may not inline due to size.
   - Expected: -1% compute

4. **Optimize `prepare_for_next_request`**: skip memmove when `parse_pos_ == buffer_size_`
   - File: `http.cpp:1152-1159`. Already handles this case at line 1032-1037 in `compact_buffer()` but `prepare_for_next_request` always does memmove.
   - Risk: None. Pure optimization.
   - Expected: -0.5-1% both

### Medium Refactors (1-4 hours, Low-Medium risk)

5. **Skip body byte validation** in `parse_available()` validation loop
   - File: `http.cpp:627-641`
   - Risk: Low. Body bytes don't need HTTP header validation. But need to ensure no security regression (e.g., null bytes in body are valid for JSON).
   - Expected: **-10-15% compute Ir**

6. **Switch hello server to `fast_router`** with hash-based dispatch
   - Files: hello server main.cpp (not in repo, but pattern from compute_api/main.cpp)
   - Risk: None. compute already uses it.
   - Expected: -8-12% hello Ir

7. **Switch hot path to `io_buffer` serialize** instead of `std::string`
   - File: `http_server.cpp` — use `serialize_into(io_buffer&)` instead of `serialize_into(std::string&)`
   - Risk: Medium. Needs io_buffer integration in connection_state.
   - Expected: -10-15% serialize Ir

8. **Pre-compute Content-Type header during dispatch** instead of re-checking in serialize
   - File: `generated_router_bindings.hpp:99-102`
   - Risk: None. Skip redundant check.
   - Expected: -2% compute

### Deep Refactors (4+ hours, Medium risk)

9. **SIMD parser validation** (SSE2/AVX2)
   - File: `http.cpp:632-641`
   - Risk: Medium. Needs careful boundary handling.
   - Expected: -30-50% parser Ir for hello, -20-30% for compute

10. **Static response template for hello** (pre-serialized envelope, content-only from handler)
    - Files: `http.cpp`, `router.hpp`, hello server
    - Risk: Medium. Changes response construction contract.
    - Expected: -50% hello serialize Ir

11. **Compile-time route table** with constexpr hashing
    - Files: `router.hpp`
    - Risk: Medium-High. Architectural change.
    - Expected: -90% dispatch Ir for static routes

### Speculative / Risky Ideas

12. **Fuse read + parse + dispatch into single function** (eliminate function call overhead)
    - Risk: High. Hurts modularity.
    - Potential: -5% from reduced function call/return overhead

13. **Custom JSON parser for compute** (skip generic serde)
    - Risk: Medium. Duplicates parsing logic.
    - Potential: -30% generated dispatch Ir

14. **Single-syscall response** (cork/uncork or MSG_MORE)
    - Risk: Medium. OS-level tuning, may not help in VM.
    - Potential: Latency improvement, especially p99

---

## Раздел 9. Final Recommendation

### Что делать первым (Day 1 — Quick Wins)

**1. Replace all string-based header lookups with `field` enum on hot paths.**
- `http.cpp:214`: `headers.get("Content-Length")` → `headers.get(field::content_length)` / `headers.contains(field::content_length)`
- `http_server.cpp:418`: `req.headers.get("Connection")` → `req.headers.get(field::connection)`
- `http_server.cpp:422`: `resp.headers.get("Connection")` → `resp.headers.get(field::connection)`

**2. Replace `ci_char_equal` with branchless ASCII lowering.**
- `http_headers.hpp:31-34`: `(a | 0x20) == (b | 0x20)` вместо `std::tolower`

**Ожидаемый combined выигрыш**: 5-8% throughput в both scenarios.

### Что делать вторым (Day 2 — High-ROI Medium Fix)

**3. Skip body byte validation in parser.**
- `http.cpp:627-641`: Ограничить validation loop только header bytes.
- Это **самый высокоROI single fix** для compute (kills ~20% of 48% parser cost).

**Ожидаемый combined выигрыш**: +10-15% compute throughput.

### Что делать третьим (Day 3 — Framework Fast Path)

**4. Switch hello to fast_router + consider io_buffer serialize path.**
- Copy `fast_router` pattern из compute into hello.
- Investigate switching `serialize_into(std::string&)` to `serialize_into(io_buffer&)` on hot path.

**Ожидаемый combined выигрыш**: +8-15% hello throughput.

### Что не трогать пока

- **SIMD parser**: High effort, can wait until after body-skip validation is validated
- **Static response cache**: Architectural change, measure after quick wins
- **Custom JSON parser**: Premature optimization until generic dispatch overhead is measured post-fixes
- **Syscall batching**: Can't reliably measure in VM environment
- **Compile-time routing**: Nice-to-have, not urgent while fast_router exists

### Лучший путь для ROI

```
Quick wins (Day 1):
  field enum lookups + tolower fix
  → Effort: 30 min. Gain: 5-8%.

Body validation skip (Day 2):
  → Effort: 1 hour. Gain: +10-15% compute, +3-5% hello.

fast_router for hello + serialize optimization (Day 3):
  → Effort: 2-3 hours. Gain: +8-15% hello.

TOTAL after 3 days: +15-25% hello, +20-30% compute.
```

Это инженерно обоснованный план, основанный на конкретных числах из perf и callgrind, с evidence от instruction-level annotate. Каждый пункт привязан к конкретному коду, конкретному проценту и конкретному сценарию.
