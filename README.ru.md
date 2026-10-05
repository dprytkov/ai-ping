![AI Ping — Claude Code + Codex](assets/readme-banner.svg)

<p align="center">
  <a href="#требования"><img alt="Windows" src="https://img.shields.io/badge/platform-Windows-0078D4?style=flat-square" /></a>
  <a href="#требования"><img alt="Windows PowerShell 5.1" src="https://img.shields.io/badge/PowerShell-5.1-5391FE?style=flat-square" /></a>
  <a href="LICENSE"><img alt="Лицензия MIT" src="https://img.shields.io/badge/license-MIT-2ea44f?style=flat-square" /></a>
</p>

<p align="center"><a href="README.md">English</a> · <strong>Русский</strong></p>

# AI Ping

**Минимальные запросы к Claude Code и Codex в Windows — с текущим аккаунтом, токенами, лимитами и временем до сброса.**

AI Ping проверяет доступ по подписке коротким запросом к модели и показывает email текущего аккаунта, токены запроса, остаток 5-часового и недельного лимитов и время до серверного сброса. Запускайте его вручную или через Планировщик заданий Windows, чтобы открыть неактивное окно до начала работы.

[Быстрый старт](#быстрый-старт) · [Использование](#использование) · [Пример вывода](#пример-вывода) · [Расписание](#расписание) · [Лицензия](#лицензия)

## Быстрый старт

Выберите команду для своего терминала.

**PowerShell 5.1 / 7** — если приглашение начинается с `PS`:

```powershell
$aiPingInstaller = Join-Path $env:TEMP 'ai-ping-install.bat'; curl.exe --fail --location --output $aiPingInstaller https://raw.githubusercontent.com/dprytkov/ai-ping/main/install.bat; if ($? -and $LASTEXITCODE -eq 0) { & $aiPingInstaller }
```

**Командная строка (`cmd.exe`):**

```bat
curl.exe --fail --location --output "%TEMP%\ai-ping-install.bat" https://raw.githubusercontent.com/dprytkov/ai-ping/main/install.bat && call "%TEMP%\ai-ping-install.bat"
```

В PowerShell используются `$env:TEMP` и `&`, а в cmd — `%TEMP%` и `call`. Команда PowerShell запускает скачанный файл только при успешном завершении curl.

Загрузчик сохраняет ZIP-архив GitHub на диск, распаковывает его и устанавливает обе команды в `%USERPROFILE%\.local\bin`. Папка добавляется в пользовательский `PATH` без дубликатов; временная папка архива удаляется.

Текст MIT устанавливается рядом с командами в файл `ai-ping-LICENSE.txt`.

**Git и права администратора не нужны.** Повтор команды обновляет установку. После завершения откройте новый терминал:

```bat
claude-ping
codex-ping
```

<details>
<summary>Установка из клона или ZIP</summary>

```powershell
git clone https://github.com/dprytkov/ai-ping.git
cd ai-ping
.\ai-ping-setup.bat
```

Или [скачайте ZIP](https://github.com/dprytkov/ai-ping/archive/refs/heads/main.zip), распакуйте и запустите `ai-ping-setup.bat`. Он должен лежать рядом с обоими ping-скриптами и `LICENSE`.

Чтобы сначала проверить интернет-загрузчик, прочитайте [install.bat](install.bat). Скачанный файл остаётся в `%TEMP%\ai-ping-install.bat` для просмотра.

</details>

## Требования

- Windows с **Windows PowerShell 5.1** и доступом к интернету.
- `curl.exe` и `tar.exe` в `PATH` для установки из интернета.
- CLI нужного провайдера со входом по подписке и доступом к выбранной модели.
- Claude Code с поддержкой `--safe-mode` и `--effort`; проверено с версией **2.1.289**.

**Вход:** запустите `claude` и выполните `/login` либо запустите `codex login`. Установщик не устанавливает CLI, не выполняет вход и не создаёт задачи по расписанию.

## Использование

| Команда | Модель по умолчанию | Запрос |
| --- | --- | --- |
| `claude-ping` | `haiku` | Короткий системный промпт, safe mode и низкий effort; инструменты и MCP отключены |
| `codex-ping` | `gpt-5.6-luna` | Прямой запрос с низким reasoning effort; переход на CLI при HTTP 401 |

Передайте имя модели единственным аргументом:

```bat
claude-ping sonnet
codex-ping gpt-5.6-sol
```

Каждый запуск делает **реальный запрос к модели и расходует лимиты аккаунта**. Доступность моделей зависит от аккаунта. Если модель по умолчанию недоступна, укажите поддерживаемое имя.

Claude отключает thinking там, где модель это поддерживает. Настройки действуют только для процесса пинга. Повторный пинг не переносит время сброса уже активного окна.

## Пример вывода

Пример Claude с условными значениями:

```text
[2026-10-05 10:00:00] OK: 'ok'
  login=claude-user@example.com
  model=haiku
  TOKENS
  input=20  output=3  total=83
  cache_write=10  cached=50

  LIMITS
  5-hour    [##------------------]  remaining=87.5%  used=12.5%
            resets=2026-10-05 12:00:00 +03:00
            in 0d 01:59:59

  weekly    [#######-------------]  remaining=65%  used=35%
            resets=2026-10-10 10:00:00 +03:00
            in 4d 23:59:59
```

| Поле | Значение |
| --- | --- |
| `login` | Email текущего аккаунта провайдера; `unavailable`, если данные недоступны |
| `TOKENS` | Токены этого пинга, включая статистику кэша |
| `used` / `remaining` | Проценты лимита аккаунта, а не точное число оставшихся токенов |
| `resets` | Серверное время сброса в часовом поясе Windows |
| `in` | Обратный отсчёт: дни и `часы:минуты:секунды` |
| `n/a` / `unknown` | Сервис не вернул значение |

Claude складывает вход без кэша, запись в кэш, чтение из кэша и ответ в `total`. У Codex кэш уже входит во вход, а reasoning — в ответ; повторно они не прибавляются. Запросы статистики лимитов не генерируют ответ модели.

**Коды выхода:** `0` — успех, `1` — ошибка. Если пинг прошёл, но статистика лимитов недоступна, выводится предупреждение и сохраняется код `0`.

## Расписание

Пример: запуск Claude Ping каждый день в **07:00 по местному времени**, когда вы вошли в Windows. Выполните в PowerShell:

```powershell
$action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c "%USERPROFILE%\.local\bin\claude-ping.bat"'
$trigger = New-ScheduledTaskTrigger -Daily -At '07:00'
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable
Register-ScheduledTask -TaskName 'claude-ping' -Action $action -Trigger $trigger -Settings $settings
```

Для Codex замените `claude-ping` на `codex-ping` в имени задачи и пути скрипта. В [подробной инструкции](ai-ping.md#запуск-по-расписанию) есть несколько запусков в день, логирование и управление задачами.

## Решение проблем

| Симптом | Что проверить |
| --- | --- |
| CLI или ping-команда не найдены | Установку и `PATH`; откройте новый терминал |
| Ошибка авторизации | Повторите вход: `claude` → `/login` либо `codex login` |
| Модель недоступна | Укажите модель, поддерживаемую вашим аккаунтом |
| Предупреждение о лимитах | Проверьте сеть и вход по подписке |
| Предупреждение антивируса | Оставьте защиту включённой; проверьте файлы и обнаружение, не добавляя исключения |

Интернет-загрузчик сохраняет файлы на диск перед вызовом локального установщика. Локальные скрипты используют PowerShell. Авторизация остаётся в профиле пользователя; резервные копии, credentials и временные профили тестов исключены из Git.

## Разработка

Сборка не требуется. Офлайн-проверки используют подставные CLI, HTTP-ответы, ZIP-архивы и изолированный реестр. Они не отправляют запросы к моделям и не используют реальные credentials.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test-claude-ping.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test-codex-ping.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test-install.ps1
```

[Сообщите о проблеме](https://github.com/dprytkov/ai-ping/issues), указав команду, версии Windows/CLI и вывод без секретных данных. Перед публикацией логов скройте email в строке `login`.

## Лицензия

[MIT](LICENSE) · © 2026 [dprytkov](https://github.com/dprytkov).

---

<p align="center"><a href="README.md">English version</a> · <a href="ai-ping.md">Подробная инструкция</a></p>
