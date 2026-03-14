# E2E Instruction Profiling Bundle

Дата сборки: 2026-03-14

Этот пакет содержит рабочие артефакты для двух E2E-сценариев:

- `hello` / Hello World
- `compute` / Compute API

Сбор выполнялся на Ubuntu VM `192.168.0.104` через SSH.

## Что внутри

- `hello_perf_saved/`
  - валидный `perf.data`
  - `report.txt` с `perf report`
  - `annotate_handle_connection.txt` с `perf annotate`
  - `wrk.txt`, `record.log`, `server.log`
- `compute_perf_saved/`
  - то же самое для Compute API
- `harness_hello/callgrind.out`
  - валидный `callgrind` dump для in-process E2E harness
- `harness_compute/callgrind.out`
  - валидный `callgrind` dump для in-process E2E harness
- `hello_callgrind_annotate.txt`
  - `callgrind_annotate --auto=yes --inclusive=yes --show=Ir`
- `compute_callgrind_annotate.txt`
  - то же самое для Compute API

## Важное ограничение VM

На этой VirtualBox VM аппаратные PMU-счётчики недоступны. Поэтому `perf stat` для `cycles`, `instructions`, `branches`, `branch-misses` возвращал `<not supported>`.

Из-за этого instruction-level путь через `perf` здесь такой:

- `perf record -e cpu-clock:u`
- `perf report`
- `perf annotate`

То есть это instruction-level аннотация по сэмплам CPU clock, а не точный retired-instructions counter.

## Почему callgrind снят через harness

Прямой запуск daemon-style серверов под `valgrind --tool=callgrind` не давал корректного финального `callgrind.out`, хотя сам Valgrind на VM исправен.

Поэтому финальный `callgrind` снят через специальный in-process E2E harness, который:

- поднимает HTTP server в том же процессе
- прогоняет конечное число реальных localhost HTTP запросов
- штатно завершает процесс

За счёт этого `callgrind.out` получился валидным и пригодным для `callgrind_annotate` / `kcachegrind`.

## Ключевые результаты

### Hello World

`perf report`:

- `25.30%` `katana::http::server::handle_connection(...)`
- `13.28%` `katana::http::response::serialize_into(...)`
- `10.14%` `katana::http::parser::parse_available()`

`perf annotate`:

- в `handle_connection` самый горячий instruction around `add 0x10(%rsi),%rax`
- локально наблюдалось около `5.72%` на этом участке

`callgrind`:

- total `Ir = 336,744,241`
- `handle_connection` около `289,329,757 Ir`
- `parse_available()` около `136,926,892 Ir`
- `serialize_into(...)` около `69,950,000 Ir`

### Compute API

`perf report`:

- `23.06%` `katana::http::parser::parse_available()`

`perf annotate`:

- в `handle_connection` самый горячий instruction around `add 0x10(%rsi),%rax`
- локально наблюдалось около `7.57%` на этом участке

`callgrind`:

- total `Ir = 665,138,914`
- `handle_connection` около `620,491,419 Ir`
- `parse_available()` около `321,761,892 Ir`
- `generated::dispatch_compute_sum(...)` около `154,601,437 Ir`

## Какие файлы открывать в первую очередь

- `hello_perf_saved/report.txt`
- `hello_perf_saved/annotate_handle_connection.txt`
- `compute_perf_saved/report.txt`
- `compute_perf_saved/annotate_handle_connection.txt`
- `hello_callgrind_annotate.txt`
- `compute_callgrind_annotate.txt`
- `harness_hello/callgrind.out`
- `harness_compute/callgrind.out`

## Неактуальные папки

Папки `hello_perf/` и `compute_perf/` остались как промежуточные ранние выгрузки. Для итогового анализа использовать нужно именно `hello_perf_saved/` и `compute_perf_saved/`.
