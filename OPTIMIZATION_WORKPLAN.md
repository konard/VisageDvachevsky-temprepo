# KATANA HTTP Server — Подробный план оптимизации

**Дата**: 2026-03-14
**Основа**: Перепроверенные выводы из `ADVERSARIAL_REVIEW.md`
**Цель**: Уменьшить latency, увеличить RPS, не ухудшить корректность

---

## Обзор плана

5 оптимизаций, отсортированных по ROI (отношению ожидаемого эффекта к сложности):

| # | Оптимизация | Ожидаемый эффект | Сложность | Файлы |
|---|-------------|-----------------|-----------|-------|
| 1 | Убрать per-request обнуление `headers_map` | LARGE (-30% self-time `handle_connection`) | LOW | `http_headers.hpp`, `http_server.hpp`, `http_server.cpp`, `http.hpp` |
| 2 | Заменить `std::tolower` на ASCII-only lowering | MEDIUM (-5% CPU в compute) | LOW | `http_utils.hpp` |
| 3 | Отложить memmove в `prepare_for_next_request` | SMALL-MEDIUM (-3-6%) | LOW | `http.cpp` |
| 4 | Перепрофилировать после шагов 1-3 | — | — | — |
| 5 | Оптимизировать сериализацию ответа | MEDIUM (-5-8%) | MEDIUM | `http.cpp` |

---

## Шаг 1: Устранить per-request обнуление `headers_map`

### 1.1 Проблема

Каждый HTTP-запрос создаёт на стеке объекты `response` и `request_context`. Конструктор `headers_map` обнуляет inline-массивы через value-initialization (`std::array<known_entry, 16> known_inline_{}`), что генерирует `rep stos` (memset) на ~960 байт.

**Доказательство из профилирования:**
- Hello: 18.81% + 12.16% + 8.47% = **39.44%** self-time `handle_connection`
- Compute: 15.71% + 9.40% + 7.22% = **32.33%** self-time `handle_connection`

**Где в коде:**
- `core/src/http_server.cpp:410-411` — создание объектов на каждый запрос:
  ```cpp
  request_context ctx{state.arena};
  response resp{&state.arena};
  ```
- `core/include/katana/core/http_headers.hpp:666-672` — `reset_storage()` обнуляет массивы:
  ```cpp
  void reset_storage() noexcept {
      known_inline_.fill({});    // 16 × 24 = 384 байт
      known_chunks_ = nullptr;
      known_size_ = 0;
      unknown_inline_.fill({});  // 8 × 24 = 192 байт
      unknown_chunks_ = nullptr;
      unknown_size_ = 0;
  }
  ```
- `core/include/katana/core/http_headers.hpp:678,681` — value-init в конструкторе:
  ```cpp
  std::array<known_entry, KNOWN_HEADERS_INLINE_SIZE> known_inline_{};   // zeroed
  std::array<unknown_entry, UNKNOWN_HEADERS_INLINE_SIZE> unknown_inline_{}; // zeroed
  ```

### 1.2 Подзадача A: Добавить `fast_reset()` в `headers_map`

**Файл**: `core/include/katana/core/http_headers.hpp`

**Что делаем**: Добавляем метод, который сбрасывает только счётчики и указатели, НЕ обнуляя данные массивов. Безопасность гарантируется тем, что `append_known_entry()` ищет пустой слот по `entry.key == field::unknown`, а `append_unknown_entry()` — по `!entry.name`.

**Важная деталь**: Поскольку `append_known_entry()` и `append_unknown_entry()` ищут свободные слоты через линейный поиск по sentinel-значению (`field::unknown` для known, `nullptr` для unknown), после `fast_reset()` в массиве могут остаться stale данные с ненулевыми ключами. Это приведёт к ложным совпадениям в `find_known_entry()` и переполнению в `append_known_entry()`.

**Решение**: Обнулять только поля-ключи (`key` для known, `name` для unknown), а не весь `entry`. Это 16×2 + 8×8 = 96 байт вместо 576.

**Пример реализации:**
```cpp
// В класс headers_map (http_headers.hpp), рядом с reset_storage():

/// Быстрый сброс: обнуляем только ключи и счётчики,
/// не трогая value-данные (они перезапишутся при записи).
void fast_reset() noexcept {
    // Обнулить ключи known_inline_ (sentinel = field::unknown = 0)
    for (auto& entry : known_inline_) {
        entry.key = field::unknown;
    }
    known_chunks_ = nullptr;
    known_size_ = 0;

    // Обнулить указатели имён unknown_inline_ (sentinel = nullptr)
    for (auto& entry : unknown_inline_) {
        entry.name = nullptr;
    }
    unknown_chunks_ = nullptr;
    unknown_size_ = 0;
}

/// Быстрый сброс с указанием арены
void fast_reset(monotonic_arena* arena) noexcept {
    arena_ = arena;
    fallback_arena_ = arena_ ? nullptr : &owned_arena_;
    fast_reset();
}
```

**Почему это безопасно:**
- `find_known_entry(field f)` (строка 568) ищет `entry.key == f` → после `fast_reset()` все key = `field::unknown`, поэтому поиск не найдёт stale данных (если `f != field::unknown`)
- `append_known_entry()` (строка 588) ищет `entry.key == field::unknown` → найдёт первый слот сразу
- `find_unknown_entry(name)` (строка 616) проверяет `entry.name != nullptr` → после `fast_reset()` все `name = nullptr`, stale данные невидимы
- `append_unknown_entry()` (строка 638) ищет `!entry.name` → найдёт первый слот сразу

### 1.3 Подзадача B: Вынести `response` в `connection_state`

**Файл**: `core/include/katana/core/http_server.hpp`

**Что делаем**: Вместо создания `response` на каждый запрос на стеке, храним его в `connection_state` и переиспользуем через `fast_reset()`.

**Пример реализации:**
```cpp
// В struct connection_state (http_server.hpp:138):
struct connection_state {
    tcp_socket socket;
    // ... существующие поля ...
    monotonic_arena arena;
    parser http_parser;
    response reusable_response;  // НОВОЕ: переиспользуемый response

    explicit connection_state(tcp_socket sock)
        : socket(std::move(sock)),
          arena(detail::HTTP_SERVER_ARENA_CAPACITY),
          http_parser(&arena),
          reusable_response(&arena)  // инициализируем с ареной
    {
        active_response.reserve(detail::HTTP_SERVER_RESPONSE_BUFFER_CAPACITY);
        // ... остальная инициализация ...
    }
    // ...
};
```

### 1.4 Подзадача C: Использовать `reusable_response` в `handle_connection`

**Файл**: `core/src/http_server.cpp`

**Что делаем**: Заменяем конструирование `response` на стеке на reset переиспользуемого объекта.

**Было** (строки 409-411):
```cpp
const auto& req = state.http_parser.get_request();
request_context ctx{state.arena};
response resp{&state.arena};
```

**Стало:**
```cpp
const auto& req = state.http_parser.get_request();
request_context ctx{state.arena};

// Переиспользуем response вместо конструирования нового
auto& resp = state.reusable_response;
resp.status = 200;
resp.reason.clear();
resp.body.clear();
resp.chunked = false;
resp.headers.fast_reset(&state.arena);
```

**Дополнительно**: Нужно добавить метод `reset()` в `response`:
```cpp
// В struct response (http.hpp:46):
void reset(monotonic_arena* arena) {
    status = 200;
    reason.clear();    // не деаллоцирует, SSO или сохраняет capacity
    body.clear();      // не деаллоцирует, сохраняет capacity
    chunked = false;
    headers.fast_reset(arena);
}
```

### 1.5 Подзадача D: Оптимизировать `reset_message_state` в парсере

**Файл**: `core/src/http.cpp`

**Что делаем**: В `reset_message_state()` (строка 1145) заменяем `request_.headers.reset(arena_)` (который вызывает `reset_storage()` с полным обнулением) на `request_.headers.fast_reset(arena_)`.

**Было** (строка 1151):
```cpp
request_.headers.reset(arena_);
```

**Стало:**
```cpp
request_.headers.fast_reset(arena_);
```

### 1.6 Как тестировать

1. **Unit-тест**: Создать `headers_map`, добавить несколько заголовков, вызвать `fast_reset()`, проверить что `size() == 0`, `empty() == true`, `get(field::connection) == nullopt`, и что можно снова добавлять заголовки.
2. **Regression-тест**: Запустить существующий E2E harness (hello + compute) и проверить корректность ответов.
3. **Perf-тест**: Перепрофилировать через `perf record -e cpu-clock:u` и проверить что `rep stos` доля упала.

**Ожидаемый эффект**: -30-35% self-time `handle_connection`, ~10-15% рост RPS.

---

## Шаг 2: Заменить `std::tolower` на ASCII-only lowering в `ascii_iequals`

### 2.1 Проблема

`http_utils::detail::ascii_iequals()` вызывает `std::tolower()` по 2 раза на символ. `std::tolower()` — locale-aware функция (делает lookup в таблице локали), что значительно дороже простого ASCII lowering.

**Доказательство из профилирования:**
- Compute perf: `tolower` = **5.19%**
- Callgrind: 1,600,000 вызовов `tolower` (800K сравнений × 2 вызова)

**Где в коде:**
- `core/include/katana/core/http_utils.hpp:20-32`:
  ```cpp
  [[nodiscard]] inline bool ascii_iequals(std::string_view lhs, std::string_view rhs) noexcept {
      if (lhs.size() != rhs.size()) {
          return false;
      }
      for (size_t i = 0; i < lhs.size(); ++i) {
          unsigned char lc = static_cast<unsigned char>(lhs[i]);
          unsigned char rc = static_cast<unsigned char>(rhs[i]);
          if (std::tolower(lc) != std::tolower(rc)) {  // ← BOTTLENECK
              return false;
          }
      }
      return true;
  }
  ```
- Вызывается из `find_content_type()` (строка 218): content-type negotiation

### 2.2 Решение: Inline ASCII lowering

**Файл**: `core/include/katana/core/http_utils.hpp`

**Вариант A — минимальный патч (заменить `std::tolower` на битовую операцию):**
```cpp
[[nodiscard]] inline bool ascii_iequals(std::string_view lhs, std::string_view rhs) noexcept {
    if (lhs.size() != rhs.size()) {
        return false;
    }
    for (size_t i = 0; i < lhs.size(); ++i) {
        unsigned char lc = static_cast<unsigned char>(lhs[i]);
        unsigned char rc = static_cast<unsigned char>(rhs[i]);
        // ASCII-only: 'A'-'Z' → 'a'-'z' через OR 0x20
        if ((lc | 0x20) != (rc | 0x20)) {
            return false;
        }
        // Дополнительная проверка для non-alpha символов:
        // '0'|0x20 == 'P'|0x20 без этой проверки
        if (lc != rc && ((lc | 0x20) < 'a' || (lc | 0x20) > 'z')) {
            return false;
        }
    }
    return true;
}
```

**Вариант B — использовать уже существующий `ci_equal_fast()` из `http_headers.hpp`:**
```cpp
// http_headers.hpp уже содержит оптимизированный SIMD ci_equal_fast().
// Можно переиспользовать его:
[[nodiscard]] inline bool ascii_iequals(std::string_view lhs, std::string_view rhs) noexcept {
    return katana::http::ci_equal_fast(lhs, rhs);
}
```

**Вариант C — самый простой и корректный:**
```cpp
[[nodiscard]] inline bool ascii_iequals(std::string_view lhs, std::string_view rhs) noexcept {
    if (lhs.size() != rhs.size()) {
        return false;
    }
    for (size_t i = 0; i < lhs.size(); ++i) {
        if (!katana::http::ci_char_equal(lhs[i], rhs[i])) {
            return false;
        }
    }
    return true;
}
```

Где `ci_char_equal` уже определён в `http_headers.hpp:35-43`:
```cpp
inline bool ci_char_equal(char a, char b) noexcept {
    if (a == b) return true;
    const unsigned char ua = static_cast<unsigned char>(a);
    const unsigned char ub = static_cast<unsigned char>(b);
    return (ua ^ ub) == 0x20 && ((ua | 0x20) >= 'a') && ((ua | 0x20) <= 'z');
}
```

**Рекомендация**: Вариант B (использовать `ci_equal_fast()`) — даёт максимальную производительность через SIMD и уже протестирован в проекте. Но требует include `http_headers.hpp` из `http_utils.hpp`, что может создать циклическую зависимость. В этом случае использовать Вариант C.

### 2.3 Как тестировать

1. **Unit-тест**: Проверить что `ascii_iequals("application/json", "Application/JSON") == true`
2. **Edge cases**: `ascii_iequals("", "")`, `ascii_iequals("a", "A")`, `ascii_iequals("123", "123")`, `ascii_iequals("a[", "A{")` (последний должен быть `false` — `[` и `{` отличаются на 0x20, но не буквы)
3. **Perf**: Проверить что `tolower` исчез из top-10 в compute perf report

**Ожидаемый эффект**: -5% CPU в compute path.

---

## Шаг 3: Отложить memmove в `prepare_for_next_request`

### 3.1 Проблема

На каждый pipelined запрос вызывается `std::memmove()` для компактификации буфера, даже если оставшиеся данные находятся в начале буфера и смещение минимально.

**Доказательство из профилирования:**
- Hello perf: `prepare_for_next_request` = **6.45%**
- `__memmove_avx_unaligned_erms` = **6.03%** (связан)

**Где в коде:**
- `core/src/http.cpp:1174-1183`:
  ```cpp
  void parser::prepare_for_next_request(monotonic_arena* arena) noexcept {
      size_t remaining = buffered_bytes();
      if (remaining == 0) {
          buffer_size_ = 0;
      } else if (parse_pos_ > 0) {
          std::memmove(buffer_, buffer_ + parse_pos_, remaining);  // ← ВСЕГДА
          buffer_size_ = remaining;
      }
      reset_message_state(arena);
  }
  ```

### 3.2 Решение: Threshold-based compaction

**Файл**: `core/src/http.cpp`

**Пример реализации:**
```cpp
void parser::prepare_for_next_request(monotonic_arena* arena) noexcept {
    size_t remaining = buffered_bytes();
    if (remaining == 0) {
        buffer_size_ = 0;
        parse_pos_ = 0;  // явный сброс для ясности
    } else if (parse_pos_ > 0) {
        // Компактифицируем только когда parse_pos_ занимает больше
        // половины буфера — иначе просто оставляем данные на месте
        // и продолжаем парсить с текущего смещения.
        if (parse_pos_ > buffer_capacity_ / 2) {
            std::memmove(buffer_, buffer_ + parse_pos_, remaining);
            buffer_size_ = remaining;
            parse_pos_ = 0;
        } else {
            // Не двигаем данные, просто обновляем размер буфера
            buffer_size_ = parse_pos_ + remaining;
            // parse_pos_ остаётся прежним — НЕ сбрасываем!
        }
    }
    reset_message_state(arena);
}
```

**ВАЖНО**: Этот патч требует проверки, что `parse_pos_` корректно учитывается в `commit_input()` и `parse_available()` при следующем запросе. Нужно убедиться, что:
- `commit_input()` добавляет новые данные после `buffer_size_`, а не после `parse_pos_`
- `parse_available()` начинает парсинг с позиции 0, а не с `parse_pos_`

Если `parse_pos_` НЕ сбрасывается в `reset_message_state()`, то текущий код уже работает корректно — парсер просто продолжит с позиции `parse_pos_` на следующем запросе. Но нужно проверить `reset_message_state`:

```cpp
// Строка 1152: parse_pos_ = 0; ← СБРАСЫВАЕТСЯ!
```

Это значит, что текущая реализация `reset_message_state` сбрасывает `parse_pos_` в 0. Если мы не делаем memmove, нужно НЕ сбрасывать `parse_pos_` — а `reset_message_state` должна знать, что данные не были перемещены.

**Альтернативный (более безопасный) подход** — вместо изменения логики `parse_pos_`, просто пропускать memmove когда `remaining` мал:

```cpp
void parser::prepare_for_next_request(monotonic_arena* arena) noexcept {
    size_t remaining = buffered_bytes();
    if (remaining == 0) {
        buffer_size_ = 0;
    } else if (parse_pos_ > 0) {
        // Всегда двигаем, но только если это имеет смысл.
        // При pipeline depth 20 данные обычно уже в начале буфера.
        // Здесь оставляем memmove, но добавляем fast-path для
        // случая когда remaining маленький (< 64 байт — одна cache line):
        if (remaining <= 64) {
            // Для маленьких остатков используем простое копирование
            // (memmove overhead на маленьких данных минимален,
            // но вызов функции и setup имеет фиксированный cost)
            std::memcpy(buffer_, buffer_ + parse_pos_, remaining);
        } else {
            std::memmove(buffer_, buffer_ + parse_pos_, remaining);
        }
        buffer_size_ = remaining;
    }
    reset_message_state(arena);
}
```

**Самый безопасный подход** (рекомендуется начать с него):
```cpp
void parser::prepare_for_next_request(monotonic_arena* arena) noexcept {
    size_t remaining = buffered_bytes();
    if (remaining == 0) {
        buffer_size_ = 0;
    } else if (parse_pos_ > 0) {
        // Откладываем memmove: если parse_pos_ < 50% буфера,
        // у нас ещё достаточно места для чтения данных следующего запроса.
        // Экономим CPU на memmove, пока не накопится фрагментация.
        if (parse_pos_ > buffer_capacity_ / 2) {
            std::memmove(buffer_, buffer_ + parse_pos_, remaining);
            buffer_size_ = remaining;
        }
        // Если НЕ двигали — не трогаем buffer_size_
        // (buffer_size_ уже включает parse_pos_ + remaining)
    }
    reset_message_state(arena);  // Внимание: сбрасывает parse_pos_ = 0
}
```

**Проблема**: `reset_message_state` всегда ставит `parse_pos_ = 0`. Поэтому нужно либо:
1. Вынести сброс `parse_pos_` из `reset_message_state`, либо
2. Передавать новый `parse_pos_` как аргумент

**Финальная рекомендуемая реализация:**
```cpp
void parser::prepare_for_next_request(monotonic_arena* arena) noexcept {
    size_t remaining = buffered_bytes();
    if (remaining == 0) {
        buffer_size_ = 0;
    } else if (parse_pos_ > 0) {
        if (parse_pos_ > buffer_capacity_ / 2) {
            std::memmove(buffer_, buffer_ + parse_pos_, remaining);
            buffer_size_ = remaining;
        } else {
            // Не двигаем данные. Запоминаем новую стартовую позицию.
            // buffer_size_ не меняем (она уже корректна).
        }
    }
    // Сбрасываем состояние парсера, но parse_pos_ настраиваем отдельно:
    size_t saved_parse_pos = (remaining > 0 && parse_pos_ <= buffer_capacity_ / 2)
                                 ? parse_pos_  // данные не двигались
                                 : 0;          // данные сдвинуты или их нет
    reset_message_state(arena);
    parse_pos_ = saved_parse_pos;
}
```

### 3.3 Как тестировать

1. **Unit-тест**: Пропарсить запрос, вызвать `prepare_for_next_request`, проверить что `buffered_bytes()` корректен
2. **Pipeline-тест**: Отправить 10+ запросов в одном TCP пакете, проверить все ответы
3. **Perf**: Проверить что доля `memmove` снизилась

**Ожидаемый эффект**: -3-6% в pipelining сценариях.

---

## Шаг 4: Перепрофилировать после шагов 1-3

### 4.1 Зачем

После устранения 30%+ самого крупного hotspot, профиль изменится. Ранее «невидимые» bottleneck'и могут стать доминирующими. Неправильно оптимизировать дальше без свежих данных.

### 4.2 Что именно запустить

```bash
# 1. perf для Hello World
perf record -e cpu-clock:u -g -- ./katana_harness_hello
perf report --stdio > hello_perf_post_opt1/report.txt
perf annotate handle_connection --stdio > hello_perf_post_opt1/annotate_handle_connection.txt

# 2. perf для Compute API
perf record -e cpu-clock:u -g -- ./katana_harness_compute
perf report --stdio > compute_perf_post_opt1/report.txt

# 3. callgrind (через in-process harness)
valgrind --tool=callgrind ./katana_harness_hello
callgrind_annotate callgrind.out.* > hello_callgrind_post_opt1.txt

valgrind --tool=callgrind ./katana_harness_compute
callgrind_annotate callgrind.out.* > compute_callgrind_post_opt1.txt

# 4. wrk benchmark для RPS/latency baseline
wrk -t4 -c100 -d30s --latency http://127.0.0.1:8080/hello
wrk -t4 -c100 -d30s --latency -s compute.lua http://127.0.0.1:8080/compute
```

### 4.3 На что смотреть

- Подтвердить исчезновение `rep stos` из top-3
- Подтвердить исчезновение `tolower` из top-10
- Определить новый top-5 hotspot'ов
- Сравнить RPS/latency с baseline (Hello: 983K RPS, 4.13ms; Compute: 851K RPS, 4.43ms)
- Проверить что P999 tail latency не деградировал

---

## Шаг 5: Оптимизировать сериализацию ответа (`serialize_into`)

### 5.1 Проблема

`serialize_into(std::string&)` делает 10+ вызовов `std::string::append()`. Каждый append делает bounds check + size update + потенциальный memcpy. При этом в коде уже существует `io_buffer`-based сериализация, которая использует прямой memcpy.

**Доказательство из профилирования:**
- Hello perf: `serialize_into` = **13.28%**, `string::append` = **4.05%** дополнительно
- Callgrind: 70M Ir (20.8% от общего)

**Где в коде:**
- `core/src/http.cpp:217-282` — 10+ вызовов `out.append()`:
  ```cpp
  void response::serialize_into(std::string& out) const {
      // ... reserve ...
      out.append(HTTP_VERSION_PREFIX);    // "HTTP/1.1 "
      out.append(status_buf, ...);        // "200"
      out.push_back(' ');                 // " "
      out.append(reason);                 // "OK"
      out.append(CRLF);                   // "\r\n"
      for (const auto& [name, value] : headers) {
          out.append(name);               // header name
          out.append(HEADER_SEPARATOR);   // ": "
          out.append(value);              // header value
          out.append(CRLF);              // "\r\n"
      }
      // ... Content-Length + final CRLF + body ...
  }
  ```

### 5.2 Решение: Прямая запись через memcpy в pre-sized буфер

**Файл**: `core/src/http.cpp`

**Пример реализации:**
```cpp
void response::serialize_into(std::string& out) const {
    if (chunked) {
        out = serialize_chunked();
        ::katana::detail::syscall_metrics_registry::instance().note_response_serialize(
            out.size(), 0, out.capacity());
        return;
    }

    // Расчёт Content-Length (без изменений)
    char content_length_buf[32];
    std::string_view content_length_value;
    const bool has_content_length = headers.contains(field::content_length);
    if (!has_content_length) {
        auto [ptr, ec] = std::to_chars(
            content_length_buf, content_length_buf + sizeof(content_length_buf), body.size());
        if (ec == std::errc()) {
            content_length_value =
                std::string_view(content_length_buf, static_cast<size_t>(ptr - content_length_buf));
        }
    }

    // Расчёт общего размера (без изменений)
    size_t headers_size = 0;
    for (const auto& [name, value] : headers) {
        headers_size += name.size() + HEADER_SEPARATOR.size() + value.size() + CRLF.size();
    }
    if (!content_length_value.empty()) {
        headers_size += 14 + HEADER_SEPARATOR.size() + content_length_value.size() + CRLF.size();
    }

    char status_buf[16];
    auto [ptr, ec] = std::to_chars(status_buf, status_buf + sizeof(status_buf), status);
    std::string_view status_sv(status_buf, static_cast<size_t>(ptr - status_buf));

    const size_t total_size = HTTP_VERSION_PREFIX.size() + status_sv.size() + 1 +
                              reason.size() + CRLF.size() + headers_size +
                              CRLF.size() + body.size();

    const size_t old_capacity = out.capacity();
    out.resize(total_size);  // resize вместо reserve + append
    char* dst = out.data();

    // Вспомогательная лямбда для записи
    auto write = [&dst](std::string_view sv) {
        std::memcpy(dst, sv.data(), sv.size());
        dst += sv.size();
    };

    write(HTTP_VERSION_PREFIX);
    write(status_sv);
    *dst++ = ' ';
    write(reason);
    write(CRLF);

    for (const auto& [name, value] : headers) {
        write(name);
        write(HEADER_SEPARATOR);
        write(value);
        write(CRLF);
    }

    if (!content_length_value.empty()) {
        write(std::string_view("Content-Length", 14));
        write(HEADER_SEPARATOR);
        write(content_length_value);
        write(CRLF);
    }

    write(CRLF);
    write(body);

    // Проверка что мы записали ровно столько, сколько ожидали
    assert(static_cast<size_t>(dst - out.data()) == total_size);

    ::katana::detail::syscall_metrics_registry::instance().note_response_serialize(
        out.size(), old_capacity, out.capacity());
}
```

**Преимущества:**
- Один `resize()` вместо множества `append()` — нет повторных bounds checks
- `memcpy` вместо `append` — компилятор может инлайнить для малых sizes
- Нет риска reallocation внутри цикла (размер точно рассчитан заранее)

### 5.3 Как тестировать

1. **Unit-тест**: Создать response с разными комбинациями заголовков, сериализовать, сравнить с эталоном
2. **Fuzz-тест**: Случайные заголовки с спец-символами
3. **Perf**: Проверить что `string::append` исчез из top-20

**Ожидаемый эффект**: -5-8% total CPU.

---

## Дополнительные наблюдения для будущих оптимизаций

### Парсер (40-48% instruction count)

Парсер — самый «тяжёлый» компонент по instruction count, но его оптимизация рискованна (парсер критичен для безопасности). Возможные направления:

1. **Объединение validation + parsing**: `contains_invalid_header_value()` — отдельный цикл, можно совместить с основным парсингом
2. **Кэширование CRLF позиций**: Найти `\r\n\r\n` один раз, построить массив смещений строк, обрабатывать заголовки по индексу
3. **Perfect hash для header fields**: Заменить binary search по 342 заголовкам на compile-time perfect hash

### owned_arena_ в headers_map

`headers_map` содержит `monotonic_arena owned_arena_{4096}` — это выделение 4096 байт в конструкторе даже при наличии внешней арены. Если `response` переиспользуется (шаг 1), эта аллокация происходит только один раз при создании `connection_state`.

### Syscall metrics overhead (1.46%)

Малый, но реальный overhead от `note_response_serialize()` и других metrics вызовов. Можно отключить в production build через `#ifdef KATANA_METRICS_ENABLED`.

---

## Порядок коммитов

1. `feat(headers): add fast_reset() to headers_map` — только новый метод, без изменения поведения
2. `feat(http): add response::reset() method` — метод reset для переиспользования response
3. `perf(server): reuse response object in handle_connection` — использование fast_reset в горячем цикле
4. `perf(parser): use fast_reset in reset_message_state` — оптимизация парсера
5. `perf(utils): replace std::tolower with ASCII lowering` — fix tolower в content negotiation
6. `perf(parser): defer memmove in prepare_for_next_request` — threshold-based compaction
7. `perf(http): optimize serialize_into with direct memcpy` — оптимизация сериализации

Каждый коммит — атомарный, можно откатить независимо.
