# Critical Review of KATANA Performance Review

Критический разбор PERFORMANCE_REVIEW.md, DEEP_ANALYSIS_REPORT.md и IMPLEMENTATION_PLAN.md.

Для каждого пункта:
- **Что вызывает сомнение**
- **Насколько сильный риск ошибки**
- **Как это проверить до внедрения**

---

## 1. Слабые места в аргументации

### 1.1 Подмена "Ir%" на "throughput %"

**Что вызывает сомнение:**
Во всех трёх документах callgrind Ir% (instruction count percentage) систематически используется как прокси для wallclock throughput impact. Например:

> «Parser — 48% Ir в compute. Устранение валидации body bytes ... даст пропорциональный выигрыш.» (PERFORMANCE_REVIEW.md, Раздел 6)

> «Ожидаемый выигрыш: +10-15% throughput в compute» (для skip body validation)

Но Ir% ≠ wallclock%. Instruction count не учитывает:
- **IPC (Instructions Per Cycle)** — разные инструкции стоят по-разному. `memcpy` может быть дешёвой (prefetchable, pipeline-friendly), а branch-miss — дорогой. Validation loop в `parse_available()` — это tight loop с предсказуемыми ветвлениями (`[[unlikely]]`), который, вероятно, имеет **высокий IPC** и стоит меньше wallclock, чем Ir% предполагает.
- **Cache effects** — callgrind симулирует I-cache, но не D-cache hierarchy реальной системы, и уж тем более не учитывает prefetching.
- **Суперскалярное выполнение** — OoO CPU может выполнять validation loop параллельно с другими операциями.

**Насколько сильный риск ошибки:** **Высокий.** Оценки throughput gain могут быть завышены в 2-3x. В документе сам автор отмечает, что «VirtualBox variance ~10%», а callgrind — основная метрика. Но потом делает конкретные throughput predictions из Ir%, что логически несовместимо.

**Как это проверить:** Сравнить perf% (cpu-clock sampling) с callgrind Ir% для тех же функций:

| Функция | perf% | Ir% | Ratio |
|---|---|---|---|
| `parse_available()` (compute) | 31.67% | 48.03% | **0.66x** |
| `serialize_into()` (hello) | 9.36% | 29.22% | **0.32x** |
| `dispatch_with_info()` (hello) | 11.85% | 15.97% | 0.74x |

Видно, что для `serialize_into()` perf% в **3x** ниже Ir%. Это означает, что serialize instructions дешёвые (memcpy/append — cache-friendly, high IPC). Оценка «+10-20% hello throughput» для serialize optimization **почти наверняка завышена в 2-3 раза**.

Аналогично, `parse_available()` в perf показывает 31.67%, а в Ir 48.03%. Это значит, что validation loop имеет высокий IPC, и реальный wallclock overhead ближе к ~32%, а не ~48%.

---

### 1.2 Противоречие в оценке `ci_char_equal` / `tolower`

**Что вызывает сомнение:**
Рекомендация 1.2 предлагает заменить `std::tolower` на `(a | 0x20) == (b | 0x20)`, и тут же объясняет, почему этот подход недостаточен:

> «`(a | 0x20) == (b | 0x20)` даёт ложные positives для символов, отличающихся на bit 0x20, но не являющихся буквами. Например: `'@'` (0x40) и `` '`' `` (0x60) дадут true.»

Затем предлагается более корректный вариант с XOR + range check. Но далее утверждается:

> «Для HTTP headers это безопасно (header names — это tokens, `@` и `` ` `` не являются token chars)»

Однако `ci_char_equal` используется не только для header names:
- Через `ci_equal_fast` → `ci_equal_short` (которая использует `|0x20` для ≤8 байт) → `ci_equal_simd_sse2` (тоже `|0x20`)
- Через `ci_equal` → `ci_hash` (FNV-1a hash с `std::tolower`)
- Через `case_insensitive_less` в binary search по rare headers

Если заменить `ci_char_equal` но **не** `ci_hash`, то hash table lookup будет вычислять хеш через `tolower`, а сравнение — через `|0x20`. Это может создать **несогласованность**: два строки, которые хешируются одинаково через `tolower`, но сравниваются по-разному через `|0x20` (или наоборот).

**Насколько сильный риск ошибки:** **Средний.** На практике HTTP header names действительно ASCII-only, и edge cases маловероятны. Но формально это нарушает инвариант: `ci_hash(a) == ci_hash(b) ⟹ ci_equal(a, b)` для любых input.

**Как это проверить:**
1. Проверить, вызывается ли `ci_char_equal` для данных, которые не являются HTTP header names (например, header values, media types).
2. Grep по вызовам `ci_equal`, `ci_equal_fast`, `ci_char_equal` — найти все call sites и убедиться, что все входные данные — ASCII tokens.
3. Убедиться, что `ci_hash` (используемый в `ci_hash` struct для unordered containers) тоже заменён на тот же метод lowering, чтобы сохранить hash/equality consistency.

**Фактически:** `ci_equal_short` и `ci_equal_simd_sse2` **уже используют `|0x20`** для lowering (строки 44-49, 60-61, 118-119 в `http_headers.hpp`). То есть `ci_char_equal` с `std::tolower` — это **только fallback** для scalar tail в SSE2/AVX2 path и для `ci_equal` default path на строке 155. Замена `ci_char_equal` делает scalar fallback consistent с SIMD path, что **корректно**. Но `ci_hash` (строка 179) по-прежнему использует `std::tolower` — это inconsistency уже **существует** в текущем коде, и review об этом не упоминает.

---

### 1.3 Утверждение о «двойном проходе» в serialize_into

**Что вызывает сомнение:**
PERFORMANCE_REVIEW.md, раздел 4.2:

> «Двойной проход по headers: первый для расчёта размера, второй для записи»

Это верно. Но IMPLEMENTATION_PLAN.md (раздел 3.1) предлагает «single-pass serialize» — и при этом **предложенный код делает ровно то же самое**: один проход для расчёта `total`, затем один проход для записи. Два прохода сохраняются. Единственное реальное изменение — более точный `reserve` (exact size вместо estimated).

**Насколько сильный риск ошибки:** **Низкий** (некорректность отсутствует), но **оценка выигрыша вводит в заблуждение.** Описание обещает «single-pass serialize», а фактически даёт «more accurate reserve». Выигрыш от более точного `reserve` минимален, если предыдущий `reserve` уже аллоцировал достаточно (а `out.reserve(32 + reason.size() + headers_size + body.size())` — вполне адекватная оценка).

**Как это проверить:** Сравнить callgrind Ir для `serialize_into` до и после. Если разница < 5% — «single-pass» claim не оправдан.

---

## 2. Слишком оптимистичные оценки выигрыша

### 2.1 Parser body validation skip: "+10-15% compute throughput"

**Что вызывает сомнение:**
IMPLEMENTATION_PLAN.md (2.1) оценивает:
> «Realistic: +10-15% compute throughput»

Разберём:
1. Parser `parse_available()` = 48.03% Ir в compute.
2. Но validation loop (строки 627-641) — лишь **часть** `parse_available()`. Остальное: request line parsing, header parsing, body state machine, buffer management.
3. callgrind annotate показывает validation loop hot instructions (`test %sil,%sil`, `jle`, `cmp $0xa,%sil`) как ~46% от parser'а (строки 50-51 PERFORMANCE_REVIEW.md). Но это 46% × 48% = **~22% total Ir**.
4. Body bytes в compute — допустим, JSON body `[1.0,2.0,...,10.0]` ≈ 60 байт. Headers ≈ 150 байт. Body — ~29% от total request size. Так что skip body validation сократит validation loop iterations на ~29%.
5. 29% от 22% = **~6% Ir reduction**.
6. Учитывая, что Ir% ≠ wallclock% (ratio ~0.66x, см. п. 1.1): реальный throughput gain ≈ **4% compute**.

Вердикт: **+10-15% — завышено в ~2.5-3.5x.** Реалистичная оценка: **+3-6% compute throughput.**

**Как это проверить:**
1. Измерить `callgrind --toggle-collect=parse_available` Ir до и после.
2. Посчитать средний размер body vs headers для canonical compute payload.
3. Запустить wrk 3× до и после, сравнить median throughput.

---

### 2.2 Суммарные оценки "top-5 = +20-30% compute"

**Что вызывает сомнение:**
Раздел 6, PERFORMANCE_REVIEW.md:
> «Если внедрить top-5: Hello: +15-25% throughput, Compute: +20-30% throughput»

Эта оценка получена **сложением** отдельных оценок. Но optimizations не аддитивны:
- Если optimization A убирает 10% Ir, а optimization B — ещё 10% Ir, суммарный выигрыш ≠ 20%. Он = 1 - (0.9 × 0.9) = **19%** в лучшем случае.
- Но хуже того: после убирания одного bottleneck, другие bottlenecks **могут не ускориться** пропорционально. Если parse_available() занимает 48% Ir и мы сокращаем его до 30%, то throughput вырастет на 1/(1-0.18) - 1 ≈ **22%** по Amdahl's Law — но только если parser был на критическом пути. Если CPU был saturated на I/O (socket read/write), то parser optimization даст **0%** throughput gain.

**Насколько сильный риск ошибки:** **Высокий.** Суммарные оценки в обзоре — upper bound при идеальных условиях, а не realistic estimate.

**Как это проверить:** Внедрить optimizations по одной, замеряя throughput после каждой. Построить кумулятивный график.

---

### 2.3 `always_inline` для `skip_ws()`: "+1% compute"

**Что вызывает сомнение:**
`skip_ws()` = 1.72% Ir (1.65M Ir). Из них function call overhead (push/pop RBP, etc.) ≈ 4-6 Ir × 164K calls ≈ 0.66-1.0M Ir. Это ~0.7-1.0% Ir, что при Ir→wallclock ratio ~0.66x даёт **~0.5% wallclock**. Но:

1. Компилятор может **уже inline** эту функцию (GCC/Clang с `-O2` или `-O3` часто inline small functions). `[[gnu::always_inline]]` — подсказка, но если функция уже inline, эффект = 0.
2. Даже если не inline: call/ret overhead для `x86_64` = ~3-5 cycles. При 164K вызовах = ~0.5-0.8M cycles. При ~1GHz effective clock в VM = ~0.5-0.8ms из ~10s benchmark = **0.005-0.008%**.

Вердикт: **+1% — завышено в 10-200x.** Реальный эффект: **unmeasurable noise** (< 0.01%).

**Как это проверить:**
1. Проверить `objdump -d` бинаря — если `skip_ws` не появляется как отдельный символ, она уже inline.
2. Если появляется — добавить `always_inline`, пересобрать, сравнить callgrind. Разница должна быть < 0.1%.

---

### 2.4 Оценка "Day 1 Quick Wins = +5-8% throughput both"

**Что вызывает сомнение:**
Day 1 включает:
- field enum lookups: +3-5% (probably ~2%, see below)
- tolower fix: +2-3% compute, +0.5-1% hello
- always_inline skip_ws: +1% compute (probably ~0%)

Для **hello**:
- field enum lookups: заменяются 2 вызова `get("Content-Length")` и 2 вызова `get("Connection")`. `string_to_field` = 7.41% Ir в hello. Каждый вызов `get(string_view)` → `string_to_field` → hash + scan. Но не все 7.41% приходится на эти 4 вызова — `string_to_field` вызывается также из parser (`process_header_line`, строка 1016). 4 hot-path calls из ~N total = оценочно **2-3% Ir reduction** в hello, что при Ir/wallclock ratio = ~0.66x → **~1.5-2% throughput**.
- tolower fix: в hello `tolower` **не в top-8** perf symbols. Эффект < 0.5%.

Реалистичная Day 1 оценка для hello: **+2-3%**, не +5-8%.

**Как это проверить:** Подсчитать точное число вызовов `string_to_field` на hot path через callgrind `--collect-jumps=yes`, затем умножить на средний Ir per call.

---

## 3. Пункты с недостаточно сильным evidence

### 3.1 `find_header_terminator` overhead в рекомендации 2.1

**Что вызывает сомнение:**
Рекомендация «skip body validation» предлагает вызывать `find_header_terminator()` на каждом `parse_available()` для определения конца headers. Но:

1. `find_header_terminator()` — это **O(N) linear scan** (строки 84-94 в `http.cpp`): побайтовый поиск `\r\n\r\n` в буфере. Это **тот же самый тип работы**, что и validation loop.
2. Для типичного request (headers ≈ 150 байт), `find_header_terminator` просканирует ~150 байт. Validation loop без fix просканирует ~210 байт (headers + body). Экономия: ~60 байт scan, но **добавляется** ~150 байт scan от `find_header_terminator`. Net effect: **больше работы**, не меньше.

Документ упоминает: «`find_header_terminator` уже вызывается на строке 646 в том же методе. Можно кешировать результат.» Но строка 646 — это **внутри другого условия** (`state_ != state::body && state_ != state::chunk_data`), т.е. они не всегда вызываются в одном и том же месте.

**Насколько сильный риск ошибки:** **Средний.** Рекомендация может дать **нулевой или отрицательный** net effect из-за overhead `find_header_terminator`. Правильная реализация — трекать позицию конца headers в state machine (однократно при обнаружении `\r\n\r\n`), а не перезапускать scan.

**Как это проверить:**
1. Реализовать fix.
2. Измерить callgrind Ir для `parse_available` **до и после**.
3. Если Ir вырос — fix вреден.

**Лучшая альтернатива:** Не вызывать `find_header_terminator` повторно. Вместо этого: когда parser переходит из state `headers` в state `body` (строка 763: `return state::body`), установить `validated_bytes_ = buffer_size_`. Это гарантирует, что при следующем вызове `parse_available()` (если parser уже в state `body`), validation loop **вообще не выполняется** благодаря условию на строке 627: `if (state_ == state::request_line || state_ == state::headers)`.

Стоп — перечитаем код. Условие на строке 627:
```cpp
if (state_ == state::request_line || state_ == state::headers) [[likely]] {
```
Это означает, что validation loop **уже пропускается** для state `body`. Проблема возникает только в одном случае: когда один `read()` вернул **и хвост headers, и начало body** одновременно. В этом случае при первом вызове `parse_available()` state ещё `headers`, но `buffer_size_` уже включает body bytes. Validation loop пройдёт по body bytes.

Но насколько это реально? В compute-canonical TCP receive buffer = 4096 байт (строка 372 `http_server.cpp`). Типичный compute request (headers + body) < 300 байт. Значит, **весь запрос скорее всего приходит в одном read()**, и validation loop действительно проходит по body bytes.

Корректный fix: после validation loop, вместо `validated_bytes_ = buffer_size_`, установить `validated_bytes_` только до конца headers. Но это требует знания позиции конца headers, что приводит нас обратно к `find_header_terminator`.

**Вывод:** Evidence для этого fix **частичный**. Нужен benchmark самого fix, а не только теоретическая оценка.

---

### 3.2 io_buffer serialize path: "уже существует!"

**Что вызывает сомнение:**
IMPLEMENTATION_PLAN.md (3.2) с энтузиазмом указывает, что `serialize_into(io_buffer&)` «уже существует» (строки 328-412 в `http.cpp`). Но:

1. Этот overload **не используется нигде** на hot path. Если бы он был готов к production, его бы уже использовали.
2. io_buffer overload на строке 337 **тоже** использует `headers.get("Content-Length")` — string lookup. Документ не отмечает этого.
3. Документ не анализирует, **почему** string overload используется вместо io_buffer на hot path. Возможные причины: io_buffer lifecycle не совместим с pipelining, или io_buffer overload не был достаточно протестирован.

**Насколько сильный риск ошибки:** **Средний.** Переключение на io_buffer может вскрыть **скрытые bugs** в io_buffer overload, который не прошёл battle-testing.

**Как это проверить:**
1. `git log --all --follow -p -- http.cpp | grep -A5 "serialize_into(io_buffer"` — найти историю этого overload (когда добавлен, тестировался ли).
2. Unit тесты: пропустить canonical workload через io_buffer path, сравнить wire output byte-for-byte.
3. `valgrind --tool=memcheck` — проверить memory safety.

---

## 4. Рекомендации, которые могут не дать E2E win

### 4.1 SIMD validation (рекомендация 2.2)

**Что вызывает сомнение:**
Предлагается SSE2 validation для 16 байт за раз. Но:

1. **Validation loop уже не является чистым bottleneck в hello.** Headers в hello = `GET / HTTP/1.1\r\nHost: ...\r\n\r\n` ≈ 50-80 байт. SIMD обрабатывает 16 байт за итерацию → 3-5 SIMD итераций + scalar tail. Setup overhead SSE2 (load constant vectors: `_mm_setzero_si128()`, etc.) ≈ 3-5 instructions per iteration. Scalar loop = 3-4 instructions per byte × 16 bytes = 48-64 instructions per "iteration". SIMD = 6-8 instructions per 16 bytes. **Выигрыш**: ~48-64 → ~6-8 = ~8x per chunk. Но для 3-5 chunks × 16 bytes = 48-80 bytes, это **экономия ~200-400 instructions** из 51.6M total Ir = **0.0008%**.

2. **CRLF check не SIMD-ифицируется** в предложенной реализации. Документ предлагает «SIMD только для `byte == 0 || byte >= 0x80`, scalar для CRLF». Но тогда нужен **второй проход** по тем же байтам для CRLF check. Net effect может быть **нулевым или отрицательным**.

3. Предложенный SIMD code (IMPLEMENTATION_PLAN.md, 2.2) **не проверяет CRLF**. Значит, он **некорректен** — он пропускает часть validation. Bare LF (`\n` без `\r`) пройдёт мимо SIMD check.

**Насколько сильный риск ошибки:** **Высокий для correctness**, **средний для performance**.

**Как это проверить:**
1. Написать unit test с bare LF в headers — проверить, что SIMD path корректно reject'ит.
2. Benchmark: callgrind Ir для `parse_available` до и после SIMD. Если разница < 2% — не стоит complexity.

---

### 4.2 Pre-built response template для hello (рекомендация 3.3)

**Что вызывает сомнение:**
Предлагается pre-compute response template:
```
HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: keep-alive\r\nContent-Length:
```

Но:

1. **Connection header не всегда "keep-alive"**. `handle_connection` (строки 418-424 в `http_server.cpp`) проверяет `Connection: close` от клиента и может установить `Connection: close` в response. Pre-built template должен учитывать оба варианта.
2. **Middleware может добавлять headers.** Если middleware добавляет `X-Request-ID`, CORS headers, etc. — template invalidируется.
3. **Handler может менять status code.** Pre-built template с `200 OK` не годится для error responses.

Документ описывает это как «+15-25% hello throughput», но не адресует инвалидацию template. Это не «optimization», а **specialization для одного конкретного endpoint**, которая сломается при любом расширении.

**Насколько сильный риск ошибки:** **Низкий** (для correctness — если правильно реализовать fallback), но **средний** для maintainability.

**Как это проверить:** Добавить middleware к hello server, убедиться что template path корректно fallback'ает на generic serialize.

---

### 4.3 Custom JSON parser для compute (рекомендация 5.4)

**Что вызывает сомнение:**
> «skip generic serde — Direct: scan for '[', then parse doubles inline»

1. JSON parsing (`skip_ws` + `parse_double` + `try_array_start` etc.) = 1.72% Ir для `skip_ws` + часть from `dispatch_compute_sum`. Суммарно JSON parsing ≈ **3-5% Ir**.
2. Custom parser сэкономит часть из этих 3-5%. Допустим, 50% → **1.5-2.5% Ir reduction**.
3. При Ir→wallclock ratio 0.66x → **~1-1.7% throughput**.
4. Документ оценивает это как «-30% generated dispatch Ir». Dispatch = 20.51% Ir, 30% от него = 6.15% Ir. Но JSON parsing — лишь часть dispatch overhead (остальное: Accept check, Content-Type check, validation, context scope). Оценка завышена.

**Насколько сильный риск ошибки:** **Низкий для correctness** (если написать тесты), но **высокий для maintainability** — дублирование парсинга.

**Как это проверить:** callgrind annotate для `dispatch_compute_sum` — разбить 20.51% Ir на sub-components. Выделить, сколько именно приходится на JSON parsing vs Accept/Content-Type checks vs validation.

---

## 5. Рекомендации, которые могут сломать correctness, HTTP semantics или maintainability

### 5.1 Skip body byte validation — потенциальный security risk

**Рекомендация:** Не валидировать body bytes (`byte == 0 || byte >= 0x80`).

**Проблема с correctness:**
Текущий validation reject'ает bytes >= 0x80 в request. Для headers это корректно (RFC 7230 §3.2: header field values — VCHAR / SP / HTAB, все < 0x80). Для body — **нет**: тело запроса может содержать UTF-8 (RFC 7230 §3.3 не ограничивает body encoding). Это означает, что **текущий код уже некорректен** — он ошибочно reject'ает UTF-8 body.

Skip body validation **исправляет существующий баг**, а не создаёт новый. Но:

1. **Null bytes (0x00) в body**: текущий код reject'ает их. После fix — они будут проходить. Для JSON body null byte = invalid JSON, и JSON parser должен его отклонить. Но если body не парсится (streaming, pass-through) — null byte может создать **injection vector** (null byte poisoning в C-строках).

2. `request_.body = std::string_view(buffer_ + parse_pos_, content_length_)` — body представлен как `string_view`. C++ `string_view` корректно обрабатывает null bytes (в отличие от C-строк). Но downstream handlers могут конвертировать в C-строку.

**Насколько сильный риск ошибки:** **Низкий-средний.** Для JSON endpoints (compute) — безопасно. Для arbitrary body handlers — нужно проверить downstream handling null bytes.

**Как это проверить:**
1. Отправить POST request с body содержащим `\x00`: `curl --data-binary $'\x00test' http://...`.
2. Проверить, что handler корректно обрабатывает (или отклоняет) такой body.
3. Отправить POST request с UTF-8 body — убедиться, что **текущий код** его reject'ает (это баг!), а **после fix** — принимает.

---

### 5.2 `(a | 0x20) == (b | 0x20)` для ci_char_equal — false positives

**Рекомендация (из PERFORMANCE_REVIEW.md, рекомендация 4.4):** Простой вариант `(a | 0x20) == (b | 0x20)`.

**Проблема с HTTP semantics:**
HTTP header field names — это tokens (RFC 7230 §3.2.6), которые ограничены символами: `!#$%&'*+-.^_`|~` + DIGIT + ALPHA. Среди них:
- `^` (0x5E) `|0x20` → `~` (0x7E)
- `~` (0x7E) `|0x20` → `~` (0x7E)
- Итого: `^` и `~` будут считаться «равными» — **false positive**.

Оба символа — валидные token chars. Теоретически header `X-Foo^Bar` и `X-Foo~Bar` будут считаться одинаковыми.

**На практике**: ни один реальный HTTP header не содержит `^` или `~` в имени. Но **формально** это нарушение RFC 7230 case-insensitive matching spec.

IMPLEMENTATION_PLAN.md предлагает более точный вариант с XOR + range check, но PERFORMANCE_REVIEW.md в разделе 4.4 предлагает оба варианта, не акцентируя, что простой вариант **некорректен**.

**Насколько сильный риск ошибки:** **Очень низкий** практически, **формально средний**.

**Как это проверить:** Unit test: `ci_char_equal('^', '~')` должен вернуть `false`. С `(a | 0x20)` вернёт `true` — **баг**. С XOR + range check вернёт `false` — корректно.

**Замечание:** `ci_equal_short` (строки 41-50 в `http_headers.hpp`) и `ci_equal_simd_sse2` (строки 106-134) **уже используют** `|0x20` без range check! Это значит, что **баг `^` == `~` уже существует** в текущем коде для строк ≤ 8 байт и в SIMD path. Performance review **не заметил** этот существующий баг. Если фиксить `ci_char_equal` правильно (с range check), нужно **также фиксить** `ci_equal_short` и SIMD paths, что меняет scope рекомендации.

---

### 5.3 Skip Accept check в generated dispatch

**Рекомендация (IMPLEMENTATION_PLAN.md, 4.2.1):**
```cpp
if (auto accept = req.headers.get(katana::http::field::accept);
    accept && !accept->empty()) [[unlikely]] {
```

**Проблема с HTTP semantics:**
RFC 7231 §5.3.2 определяет, что если клиент отправляет `Accept` header, сервер **SHOULD** вернуть 406 Not Acceptable, если не может предоставить content в запрошенном формате. `[[unlikely]]` — подсказка компилятору, но **не меняет семантику**. Текущий код уже правильно обрабатывает Accept.

Реальное предложение здесь — просто добавить `[[unlikely]]` к существующему условию. Это **не пропуск Accept check**, а **branch prediction hint**. Название рекомендации «Skip Accept check» — misleading.

**Насколько сильный риск ошибки:** **Нулевой** (семантика не меняется, только branch hint).

**Как это проверить:** Не нужно — изменение семантически neutral.

---

### 5.4 Замена `get("Connection")` на `get(field::connection)` — скрытое поведенческое изменение

**Рекомендация:** `req.headers.get("Connection")` → `req.headers.get(field::connection)`.

**Потенциальная проблема:**
`get(string_view)` вызывает `string_to_field(name)`, и если field = `unknown`, ищет в `unknown_entries`. `get(field)` ищет **только в known_entries**. Если header `Connection` был установлен через `set_unknown_borrowed` (а не `set_known_borrowed`), то `get(field::connection)` его **не найдёт**, а `get("Connection")` — найдёт (через `string_to_field` → `field::connection` → `get(field)`).

Однако, в `process_header_line` (строки 1016-1022 в `http.cpp`): `string_to_field(name)` вызывается для каждого header. Если результат ≠ `unknown`, header устанавливается через `set_known_borrowed`. Для `Connection` (популярный header) — `string_to_field("Connection")` вернёт `field::connection`. Значит, Connection header **всегда** устанавливается как known. Замена безопасна.

**Но**: если кто-то вручную вызывает `headers.set_unknown("Connection", value)` — это сломается. Grep по коду не показывает такого использования в текущих файлах.

**Насколько сильный риск ошибки:** **Очень низкий.** Parser всегда устанавливает known headers через `set_known_borrowed`.

**Как это проверить:** `grep -r "set_unknown.*Connection" .` — должен вернуть 0 результатов.

---

## 6. Общие структурные проблемы обзора

### 6.1 VirtualBox bias не проанализирован

Документ корректно отмечает, что profiling проводился в VirtualBox без PMU. Но **не анализирует**, как это влияет на выводы:
- В VM context switches и VM exit/enter overhead могут **доминировать** для I/O bound workloads. wrk throughput в VM может быть **ограничен VM overhead**, а не application code.
- Если VM overhead = 30%, то максимальный теоретический throughput gain от application optimization = 70% × optimization%.

### 6.2 Отсутствие анализа I/O bound vs CPU bound

Ни один из документов не анализирует, является ли workload CPU bound или I/O bound:
- wrk -t4 -c512 = 512 concurrent connections. При 1.3M req/s и 4 threads, каждый thread обрабатывает ~325K req/s = ~3μs per request.
- Если syscall overhead (epoll_wait + read + write) = 1-2μs per request, то I/O = 33-66% of request lifecycle.
- Оптимизации application code (parse + serialize + dispatch) влияют только на CPU-bound часть.

Без этого анализа невозможно оценить **потолок** возможного improvement.

### 6.3 Нет sensitivity analysis для canonical payload size

Все оценки привязаны к конкретному compute payload. Если payload size изменится (e.g., 100 doubles вместо 10), пропорции bottlenecks **существенно изменятся**:
- Parser validation cost вырастет линейно с payload size.
- Serialize cost останется примерно тем же.
- Router/dispatch cost останется тем же.

Оценки выигрыша от skip body validation **зависят от payload size**, но документ не указывает, для какого конкретно payload size даны оценки.

---

## 7. Итоговая таблица критических замечаний

| # | Пункт обзора | Тип проблемы | Серьёзность | Резюме |
|---|---|---|---|---|
| 1.1 | Ir% → throughput% | Слабая аргументация | **Высокая** | Ir% завышает реальный wallclock impact в 1.5-3x; все throughput оценки систематически оптимистичны |
| 1.2 | ci_char_equal / tolower inconsistency | Слабая аргументация | Средняя | `ci_hash` всё ещё использует `tolower`, существующий `|0x20` баг в SIMD paths не упомянут |
| 1.3 | "Single-pass serialize" | Слабая аргументация | Низкая | Предложенный код по-прежнему двухпроходный, отличие — только точность reserve |
| 2.1 | Parser body skip: +10-15% | Завышенная оценка | **Высокая** | Реалистично +3-6% для canonical payload |
| 2.2 | Суммарно top-5: +20-30% | Завышенная оценка | **Высокая** | Optimizations не аддитивны, I/O bound не учтён |
| 2.3 | always_inline skip_ws: +1% | Завышенная оценка | Средняя | Реальный эффект < 0.01%, unmeasurable |
| 2.4 | Day 1 quick wins: +5-8% | Завышенная оценка | Средняя | Реалистично +2-3% для hello |
| 3.1 | find_header_terminator overhead | Недостаточный evidence | Средняя | Предложенный fix может дать нулевой или отрицательный net effect |
| 3.2 | io_buffer path "уже существует" | Недостаточный evidence | Средняя | Не используется на hot path — возможно, по причине (bugs, API mismatch) |
| 4.1 | SIMD validation | Нет E2E win | Средняя | Для коротких hello headers экономия ~0.001%, CRLF check не SIMD-ифицирован |
| 4.2 | Pre-built response template | Нет E2E win (general case) | Средняя | Работает только для одного endpoint, любое расширение сломает template |
| 4.3 | Custom JSON parser | Нет E2E win | Низкая | JSON parsing = 3-5% Ir, custom parser даст ~1% throughput, ценой maintainability |
| 5.1 | Skip body validation — null bytes | Correctness risk | Средний | Null bytes в body могут пройти, downstream handlers могут быть уязвимы |
| 5.2 | `\|0x20` для ci_char_equal | Correctness risk | Низкий | `^` == `~` false positive; **уже существует** в SIMD paths |
| 5.4 | get(field::connection) | Correctness risk | Очень низкий | Безопасно, если Connection всегда парсится как known header |

---

## 8. Рекомендации по верификации

### Для каждого предложенного fix:

1. **Измерить реальный wallclock effect**, а не Ir delta. Использовать wrk median из 5+ прогонов.
2. **Проверить Amdahl's Law ceiling**: определить I/O bound vs CPU bound ratio для canonical workload.
3. **Тестировать edge cases**: bare LF, null bytes in body, UTF-8 body, `^` vs `~` в header names.
4. **Не складывать оценки**: внедрять по одной, замерять кумулятивно.
5. **Benchmark на bare metal**, не в VirtualBox, для финальной оценки.

### Приоритеты (скорректированные):

| # | Fix | Реалистичная оценка | Confidence | Рекомендация |
|---|---|---|---|---|
| 1 | field enum lookups | +1.5-2.5% throughput | High | **Делать** — zero risk, очевидный выигрыш |
| 2 | tolower → branchless (с XOR+range) | +1-2% compute | High | **Делать** — zero risk, но фиксить и SIMD paths |
| 3 | Skip body validation | +3-6% compute | Medium-High | **Делать** — но fix правильно (через state machine, не через `find_header_terminator`) |
| 4 | Hello fast_router | +3-6% hello | High | **Делать** — proven pattern |
| 5 | SIMD parser | < 1% для typical payloads | Low | **Отложить** — ROI не оправдывает complexity |
| 6 | io_buffer serialize | +2-5% | Medium | **Исследовать** — сначала понять, почему не используется |
| 7 | Static response template | Significant, но fragile | Medium | **Отложить** — ограниченная применимость |
| 8 | always_inline skip_ws | ~0% | Very Low | **Не делать** — unmeasurable effect |
