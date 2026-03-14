# KATANA Optimization Implementation Plan (Revised)

Основа: `DEEP_ANALYSIS_REPORT.md`, adjudicated verdict и текущий код в `katana/core`.

Этот вариант заменяет прежний optimistic rollout. Здесь оставлены только шаги с нормальным ROI и исправлены критерии валидации.

## Core Corrections

- `Ir%` не используется как прямой proxy для `throughput%`.
- Выигрыши не суммируются линейно.
- Изменения меньше примерно `3%` E2E в VirtualBox считаются пограничными и валидируются не только `wrk`, но и `callgrind`/correctness.
- Для `string_to_field` и `tolower` не ставится жёсткая цель "полностью исчезнуть". Важно, чтобы просел вклад hot callsites и связанных функций.
- Для parser fix первична корректность, потом `callgrind`, потом уже `wrk`.

## Updated Phase 0: Baseline

Цель: иметь один зафиксированный baseline перед любыми правками.

1. Прогнать `hello-canonical` и `compute-canonical` по `wrk` 5 раз, взять median.
2. Снять reduced `callgrind` pass для обоих сценариев.
3. Сохранить commit hash и конфиг запуска рядом с артефактами.

Критерии:

- разброс `wrk` не больше ~10%;
- `callgrind` стабилен;
- baseline лежит в одном месте и используется для всех сравнений.

## Updated Phase 1: Safe Patches

Цель: быстрые и почти нулевые по риску правки.

Ожидаемый суммарный эффект: примерно `+2%..+4%` E2E.

### 1. Replace string-based hot-path header lookups

Файлы:

- [http.cpp](/Users/Ya/OneDrive/Desktop/KATANA/katana/core/src/http.cpp)
- [http_server.cpp](/Users/Ya/OneDrive/Desktop/KATANA/katana/core/src/http_server.cpp)

Точки:

- `response::serialize_into(std::string&)`
- `response::serialize_head_into(std::string&)`
- `handle_connection(...)`

Замены:

```diff
- bool has_content_length = headers.get("Content-Length").has_value();
+ bool has_content_length = headers.contains(field::content_length);
```

```diff
- auto connection_header = req.headers.get("Connection");
+ auto connection_header = req.headers.get(http::field::connection);
```

```diff
- if (!resp.headers.get("Connection")) {
+ if (!resp.headers.contains(http::field::connection)) {
```

Валидация:

- не требовать глобального падения `string_to_field` на фиксированный процент;
- проверить, что string-based lookup исчез из изменённых callsites;
- посмотреть, что просел вклад `serialize_into` / `handle_connection`;
- smoke test для `Connection: close` и keep-alive.

### 2. Replace `std::tolower` in `ci_char_equal`

Файл:

- [http_headers.hpp](/Users/Ya/OneDrive/Desktop/KATANA/katana/core/include/katana/core/http_headers.hpp)

Замена:

```cpp
if (a == b) return true;
unsigned char ua = static_cast<unsigned char>(a);
unsigned char ub = static_cast<unsigned char>(b);
return (ua ^ ub) == 0x20 && ((ua | 0x20) >= 'a') && ((ua | 0x20) <= 'z');
```

Почему так:

- не использовать наивное `| 0x20`;
- не требовать, чтобы `tolower` полностью исчез из всего профиля;
- цель: заметно уменьшить его вклад на compute hot path.

Валидация:

- unit-level checks для `A/a`, `Z/z`, `^/~`, `@/\``;
- `perf report` или `callgrind`: вклад `tolower`/связанного fallback path должен заметно просесть, но не обязательно уйти в ноль.

### 3. Skip useless `memmove` in `prepare_for_next_request`

Файл:

- [http.cpp](/Users/Ya/OneDrive/Desktop/KATANA/katana/core/src/http.cpp)

Точка:

- `parser::prepare_for_next_request()`

Идея:

```diff
if (remaining == 0) {
    buffer_size_ = 0;
} else if (parse_pos_ > 0) {
    std::memmove(...);
    buffer_size_ = remaining;
}
```

Валидация:

- pipelining smoke test;
- отсутствие регрессий по memcheck/ASan, если доступно.

## Updated Phase 2: Parser Body-Validation Fix

Цель: исправить over-scan body bytes и не сломать parser semantics.

Ожидаемый эффект: примерно `+3%..+6%` для compute, `+1%..+2%` для hello.

### Current Code Reality

Сейчас есть два уровня проверки:

1. В `parse_available()` идёт верхнеуровневый pre-scan по `buffer_[validated_bytes_..buffer_size_)`.
2. В `parse_request_line_state()` и `parse_headers_state()` уже есть отдельная line-level валидация для request line и header lines.

Это важно: parser уже повторно валидирует request/header bytes после top-level loop.

### Real Problem

В [http.cpp](/Users/Ya/OneDrive/Desktop/KATANA/katana/core/src/http.cpp) top-level loop в `parse_available()` бежит до `buffer_size_` пока `state_` ещё `request_line` или `headers`.

Если один `read()` принёс и `headers`, и начало `body`, pre-scan проходит и по body bytes. Это:

- даёт лишнюю работу;
- ошибочно режет `UTF-8` body bytes (`>= 0x80`);
- смешивает header validation и body payload semantics.

### Recommended Implementation Strategy

Нужен минимальный patch, а не большой parser rewrite.

Файлы:

- [http.hpp](/Users/Ya/OneDrive/Desktop/KATANA/katana/core/include/katana/core/http.hpp)
- [http.cpp](/Users/Ya/OneDrive/Desktop/KATANA/katana/core/src/http.cpp)

#### State change

Добавить в `parser` одно поле:

```cpp
size_t header_end_pos_ = 0;
```

Сбрасывать в `reset_message_state()`.

#### Validation change

В `parse_available()`:

- использовать `header_end_pos_` как верхнюю границу top-level pre-scan;
- если `header_end_pos_ == 0` и в буфере уже потенциально есть полный header block, разрешается один раз найти `\r\n\r\n` и закэшировать позицию;
- после этого сканировать только до `header_end_pos_`, а не до `buffer_size_`.

Ключевое уточнение:

- не строить rollout на требовании "никакого `find_header_terminator()` вообще";
- запрещён именно повторный O(N) scan на каждом проходе как основной алгоритм;
- допустим один cached discovery path на request, если это самый маленький diff.

#### Why this is still acceptable

После проверки текущего кода видно, что полностью state-machine-only вариант без дополнительного discovery path здесь не получается бесплатным образом:

- `parse_headers_state()` узнаёт конец headers только после того, как top-level loop уже отработал;
- значит, для первого буфера с `headers + body` нужно либо один раз найти terminator заранее, либо делать более глубокий рефакторинг порядка валидации.

Для текущего этапа план рекомендует именно первый вариант: небольшой cached fix, а не архитектурный parser rewrite.

### Patch Sequence

1. Добавить `header_end_pos_` в `parser` в [http.hpp](/Users/Ya/OneDrive/Desktop/KATANA/katana/core/include/katana/core/http.hpp).
2. Сбрасывать его в `reset_message_state()` в [http.cpp](/Users/Ya/OneDrive/Desktop/KATANA/katana/core/src/http.cpp).
3. В `parse_available()` ограничить `validation_limit`.
4. Не трогать line-level validation в `parse_request_line_state()` и `parse_headers_state()`.

### Validation Order

Сначала correctness:

1. POST с UTF-8 body должен проходить parser layer.
2. Body с `NUL` не должен отбрасываться parser'ом только из-за top-level scan.
3. Partial headers across multiple reads не должны ломаться.
4. Pipelined requests не должны ломаться.

Потом profiling:

1. Сравнить `parse_available` в `callgrind`.
2. Только после этого смотреть median `wrk`.

Важно:

- если cached terminator discovery сам съедает выигрыш, patch надо откатить и перевести пункт в более глубокий parser refactor backlog;
- не принимать fix только по `wrk`, если correctness не закрыт.

## Updated Phase 3: Routing And Generated Dispatch

Цель: закрыть оставшиеся high-confidence improvements после safe patches и parser fix.

### 1. Switch hello to `fast_router`

Ожидаемый эффект: примерно `+3%..+6%` для hello.

Это отдельный локальный шаг:

- не зависит от parser fix;
- не требует трогать generic router;
- можно делать после Step 1, если нужен быстрый hello-specific gain.

### 2. Fix generated dispatch string lookups

Файл:

- [generated_router_bindings.hpp](/Users/Ya/OneDrive/Desktop/KATANA/examples/codegen/compute_api/generated/generated_router_bindings.hpp)

Меняем только явные hot-path string cases:

```diff
- out.set_header("Content-Type", kJsonContentType);
+ out.set_header(katana::http::field::content_type, kJsonContentType);
```

```diff
- !out.headers.get(katana::http::field::content_type)
+ !out.headers.contains(katana::http::field::content_type)
```

Ожидаемый эффект: примерно `+1%..+2%` для compute.

## Deferred

Пока не делать:

- `always_inline skip_ws`;
- custom JSON parser;
- SIMD parser validation;
- speculative serialize rewrite под "single-pass";
- `io_buffer` hot-path switch без отдельного расследования, почему он сейчас не используется;
- static response template как framework-level решение;
- `writev` / zero-copy rollout в VirtualBox.

Причина общая:

- либо ROI слишком слабый;
- либо нет достаточного evidence;
- либо окружение не позволяет честно померить.

## Updated First Patch Set

Делать сейчас:

1. enum-based header lookups в [http.cpp](/Users/Ya/OneDrive/Desktop/KATANA/katana/core/src/http.cpp)
2. enum-based header lookups в [http_server.cpp](/Users/Ya/OneDrive/Desktop/KATANA/katana/core/src/http_server.cpp)
3. `ci_char_equal` fix в [http_headers.hpp](/Users/Ya/OneDrive/Desktop/KATANA/katana/core/include/katana/core/http_headers.hpp)
4. `prepare_for_next_request()` fast path в [http.cpp](/Users/Ya/OneDrive/Desktop/KATANA/katana/core/src/http.cpp)

Делать сразу после них, но только с correctness-first validation:

5. parser body-validation fix в [http.hpp](/Users/Ya/OneDrive/Desktop/KATANA/katana/core/include/katana/core/http.hpp) и [http.cpp](/Users/Ya/OneDrive/Desktop/KATANA/katana/core/src/http.cpp)

Потом:

6. hello `fast_router`
7. generated dispatch lookup cleanup

## Realistic Outcome

После первых safe patches:

- ждать скорее `+2%..+4%`, а не двузначные числа.

После safe patches + parser fix + routing/dispatch cleanup:

- compute: примерно `+4%..+8%`;
- hello: примерно `+4%..+7%`.

Если дальше понадобится новый optimisation pass, его уже надо строить на новом профиле после этих изменений, а не на старом bundle.
