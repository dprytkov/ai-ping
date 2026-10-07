![AI Ping — Claude Code + Codex](assets/readme-banner.svg)

<p align="center">
  <a href="#требования-windows"><img alt="Windows" src="https://img.shields.io/badge/platform-Windows-0078D4?style=flat-square" /></a>
  <a href="#linux"><img alt="Linux" src="https://img.shields.io/badge/platform-Linux-FCC624?style=flat-square" /></a>
  <a href="#требования-windows"><img alt="Windows PowerShell 5.1" src="https://img.shields.io/badge/PowerShell-5.1-5391FE?style=flat-square" /></a>
  <a href="LICENSE"><img alt="Лицензия MIT" src="https://img.shields.io/badge/license-MIT-2ea44f?style=flat-square" /></a>
</p>

<p align="center"><a href="README.md">English</a> · <strong>Русский</strong></p>

# AI Ping

**Минимальные запросы к Claude Code и Codex в Windows и Linux — с текущим аккаунтом, токенами, лимитами и временем до сброса.**

AI Ping проверяет доступ по подписке коротким запросом к модели и показывает email текущего аккаунта, токены запроса, остаток 5-часового и недельного лимитов и время до серверного сброса. Запускайте его вручную, через Планировщик заданий Windows или cron в Linux, чтобы открыть неактивное окно до начала работы.

[Быстрый старт](#быстрый-старт) · [Linux](#linux) · [Использование](#использование) · [Пример вывода](#пример-вывода) · [Расписание](#расписание) · [Лицензия](#лицензия)

## Быстрый старт

Выберите команду для своего терминала.

**Linux / WSL:**

```bash
curl -fsSL https://raw.githubusercontent.com/dprytkov/ai-ping/main/install.sh | bash
```

Подходит для разных дистрибутивов Linux с нужными зависимостями; зависимости и расписание описаны в разделе [Linux](#linux).

**Windows PowerShell (5.1 / 7):**

```powershell
irm https://raw.githubusercontent.com/dprytkov/ai-ping/main/install.ps1 | iex
```

**Windows CMD:**

```bat
curl -fsSL https://raw.githubusercontent.com/dprytkov/ai-ping/main/install.bat -o install.bat && install.bat && del install.bat
```

В Windows загрузчик сохраняет ZIP-архив GitHub на диск, распаковывает его и устанавливает `ai-ping`, `claude-ping` и `codex-ping` в `%USERPROFILE%\.local\bin`. Папка добавляется в пользовательский `PATH` без дубликатов; временная папка архива удаляется. PowerShell также удаляет временный загрузчик, а CMD удаляет `install.bat` после успешной установки.

Текст MIT устанавливается рядом с командами в файл `ai-ping-LICENSE.txt`.

**Git и права администратора не нужны.** Повтор команды обновляет установку. После завершения откройте новый терминал:

```bat
ai-ping
```

<details>
<summary>Установка из клона или ZIP</summary>

```powershell
git clone https://github.com/dprytkov/ai-ping.git
cd ai-ping
.\ai-ping-setup.bat
```

Или [скачайте ZIP](https://github.com/dprytkov/ai-ping/archive/refs/heads/main.zip), распакуйте и запустите `ai-ping-setup.bat`. Он должен лежать рядом со всеми тремя ping-скриптами и `LICENSE`.

Чтобы сначала проверить интернет-загрузчики, прочитайте [install.ps1](install.ps1), [install.bat](install.bat) или [install.sh](install.sh).

</details>

## Linux

Подходит любой дистрибутив Linux, включая WSL, с Bash, Python 3.8+, службой cron и пользовательской командой `crontab`, `flock` (util-linux), coreutils, awk, grep, curl, tar, gzip и tzdata. Установите недостающие зависимости пакетным менеджером своего дистрибутива и включите его службу cron (`cron` или `crond`, в зависимости от дистрибутива). В WSL расписание работает, пока запущены дистрибутив и его служба cron.

CLI необязательны: если `claude` или `codex` отсутствует, установщик попросит вставить авторизацию из Windows. Если CLI установлен, выполните вход под тем пользователем, от которого будут запускаться пинги. Используется стандартная библиотека Python, без pip-пакетов и jq.

Из клона или распакованного архива запустите установщик **без sudo**:

```bash
bash ai-ping-setup.sh --start 06:00 --provider both
```

Без аргументов установщик спросит время первого запуска и провайдера: `both`, `claude` или `codex` (по умолчанию `06:00` и `both`). Ежедневное расписание по умолчанию — **06:00, 11:01, 16:02, 21:03 по московскому времени Windows** (`Europe/Moscow`, UTC+3), даже если Linux-сервер работает в UTC или другом часовом поясе. Интервал — 5 часов 1 минута. Например, `--start 07:30` даст **07:30, 12:31, 17:32, 22:33**. Если Windows использует другой пояс, укажите соответствующее имя IANA через `--timezone`, например `--timezone Europe/Berlin`. Проверить пояс Windows можно командой PowerShell `Get-TimeZone`. Без интерактивного терминала используются значения расписания по умолчанию, но при отсутствии выбранного CLI нужна уже сохранённая авторизация. Аргументы `--start` и `--provider` не отменяют необходимый запрос авторизации. Позже 23:00 в выбранном поясе новые запуски не назначаются; начатый запрос может завершиться позже. Пропущенные при выключенном компьютере запуски не догоняются.

Интернет-загрузчик скачивает и распаковывает репозиторий, затем вызывает тот же установщик:

```bash
curl -fsSL https://raw.githubusercontent.com/dprytkov/ai-ping/main/install.sh | bash
```

В `~/.local/bin` устанавливаются `ai-ping`, `claude-ping`, `codex-ping`, общий `ai-ping.py`, `ai-ping-run` и `ai-ping-LICENSE.txt`. Установщик добавляет блок PATH без дубликатов в `.profile` и `.bashrc`; после установки откройте новый терминал Bash. Повторная установка обновляет скрипты и заменяет только свой блок crontab, сохраняя чужие задачи. Во время установки запросы к моделям не отправляются.

```bash
claude-ping sonnet
codex-ping gpt-5.6-sol
crontab -l
tail -n 40 ~/.local/state/ai-ping/ai-ping.log
```

Для моделей по расписанию есть `--claude-model sonnet --codex-model gpt-5.6-sol`. Плановый запуск сохраняет PATH на момент установки, а также заданные `CLAUDE_CONFIG_DIR` и `CODEX_HOME`, использует авторизацию того же пользователя и блокирует одновременные плановые пинги. Cron проверяет время в выбранном поясе каждую минуту; запросы к моделям выполняются только в часы расписания, указанные в его помеченном комментарии. Часовой пояс сервера и чужие cron-задачи не меняются. При ошибке одного провайдера второй всё равно запускается. Вход в SSH не требуется, пока компьютер и cron работают. Лог может содержать email аккаунта. Для отмены расписания удалите блок `# BEGIN AI-PING` / `# END AI-PING` через `crontab -e`. [Подробная инструкция Linux](ai-ping.md#linux).

### Как скопировать авторизацию из Windows

Для каждого выбранного провайдера без CLI в Linux установщик покажет команду копирования и попросит вставить её результат. На компьютере Windows, где вы пользуетесь своим аккаунтом, откройте **Пуск → введите PowerShell → откройте Windows PowerShell**. Права администратора не нужны.

**Claude (рекомендуется для cron без CLI в Linux):** выполните `claude setup-token` в PowerShell и подтвердите доступ в браузере. Скопируйте показанный токен и вставьте в запрос установщика Linux. Он действует один год и разрешает запросы к модели; AI Ping пропускает запрос статистики и сообщает, что лимиты аккаунта недоступны. [Долгоживущий токен Claude](https://code.claude.com/docs/en/authentication#generate-a-long-lived-token).

Для вывода лимитов можно вместо этого перенести JSON обычного входа с временным токеном: выполните `claude`, введите `/login`, войдите в аккаунт и выйдите из Claude Code. Затем вставьте в PowerShell эту команду и нажмите Enter:

```powershell
$aiPingAuthDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }; Get-Content -Raw -LiteralPath (Join-Path $aiPingAuthDir '.credentials.json') | ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress | Set-Clipboard
```

Команда скопирует авторизацию из `%USERPROFILE%\.claude\.credentials.json` одной строкой. Её access-токен истекает независимо от скопированного файла и без Claude CLI в Linux не продлевается. Для автоматических запусков с лимитами установите Claude CLI в Linux и выполните вход там, чтобы CLI мог обновлять авторизацию. [Где Claude хранит авторизацию](https://code.claude.com/docs/en/authentication).

**Codex:** выполните `codex login` и войдите через аккаунт ChatGPT. Затем вставьте в PowerShell:

```powershell
$aiPingAuthDir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }; Get-Content -Raw -LiteralPath (Join-Path $aiPingAuthDir 'auth.json') | ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress | Set-Clipboard
```

Команда скопирует авторизацию из `%USERPROFILE%\.codex\auth.json` одной строкой. Если файла нет, откройте `.codex\config.toml` в своей папке пользователя Windows через Блокнот, задайте `cli_auth_credentials_store = "file"`, снова выполните `codex login` и повторите копирование. Если задан `CODEX_HOME`, используйте эту папку. Обе команды учитывают нестандартные папки профилей. [Хранение и перенос авторизации Codex](https://learn.chatgpt.com/docs/auth).

Вернитесь в запрос установщика Linux, вставьте текст через **Ctrl+Shift+V** или правую кнопку мыши и нажмите Enter. Вставка скрыта — это нормально. Для каждого провайдера вставляйте его собственный текст. Неправильный формат вызовет повторный запрос; секретный текст не выводится. При повторной установке нажмите Enter, чтобы оставить сохранённую авторизацию, либо вставьте новую для замены копии AI Ping.

AI Ping сохраняет только access-токен, права Claude (`scopes`), если они указаны, и данные аккаунта/идентификации Codex в `~/.local/state/ai-ping/credentials/`: права файлов `600`, папки `700`. Файлы CLI не перезаписываются, refresh-токены не сохраняются. Это секрет, как пароль: не отправляйте его в чаты и не передавайте аргументом команды. После переноса очистите буфер Windows командой `Set-Clipboard -Value ''`. Без CLI пинги используют прямые HTTP-запросы, а импортированные токены автоматически не обновляются. При HTTP 401 создайте свежую авторизацию в Windows и повторите установку; для долгоживущего токена Claude снова выполните `claude setup-token`. Без CLI Claude email выводится как `login=unavailable`. Токен, вставленный обычной строкой, считается токеном только для запросов к модели от `setup-token`, и статистика лимитов не запрашивается; JSON входа с расширенными или неизвестными правами сохраняет запрос статистики. Это действует для ручных и плановых запусков; недоступность лимитов не меняет успешный код выхода пинга. Прямой запрос Claude поддерживает `haiku`, `sonnet`, `opus` или полное имя модели API; инструменты и thinking отключены.

## Требования Windows

- Windows с **Windows PowerShell 5.1** и доступом к интернету.
- `curl.exe` и `tar.exe` в `PATH` для установки из интернета.
- CLI нужного провайдера со входом по подписке и доступом к выбранной модели.
- Claude Code с поддержкой `--safe-mode` и `--effort`; проверено с версией **2.1.289**.

**Вход:** запустите `claude` и выполните `/login` либо запустите `codex login`. Установщики не устанавливают CLI и не выполняют вход; Linux-установщик может импортировать авторизацию из Windows при отсутствии CLI. Windows-установщик не создаёт задачи по расписанию; Linux-установщик создаёт расписание cron, описанное выше.

## Использование

Выполните `ai-ping` без аргументов для запуска Codex, затем Claude с моделями по умолчанию в Windows или Linux. При ошибке одного второй всё равно запускается. Код выхода — `0`, если оба пинга успешны, иначе `1`. Для выбора модели используйте отдельные команды ниже.

| Команда | Модель по умолчанию | Запрос |
| --- | --- | --- |
| `ai-ping` | Обе модели ниже | Запускает Codex, затем Claude; при ошибке одного выполняет второй |
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
| `resets` | Серверное время сброса в часовом поясе компьютера |
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
| Ошибка авторизации | Повторите вход: `claude` → `/login` либо `codex login`; без CLI в Linux повторите установку и вставьте свежую авторизацию из Windows |
| Модель недоступна | Укажите модель, поддерживаемую вашим аккаунтом |
| Предупреждение о лимитах | Проверьте сеть и вход по подписке |
| Предупреждение антивируса | Оставьте защиту включённой; проверьте файлы и обнаружение, не добавляя исключения |

Интернет-загрузчики сохраняют файлы на диск перед вызовом локального установщика. Windows-скрипты используют PowerShell, Linux-скрипты — Bash и Python 3. Авторизация остаётся в профиле пользователя; резервные копии, credentials и временные профили тестов исключены из Git. В Linux Codex читает `CODEX_HOME/auth.json` (по умолчанию `~/.codex/auth.json`), Claude — `CLAUDE_CONFIG_DIR/.credentials.json` (по умолчанию `~/.claude/.credentials.json`). При отсутствии CLI провайдера его импортированная авторизация AI Ping имеет приоритет, если сохранена. Прямому запросу Codex нужна авторизация ChatGPT в файле.

## Разработка

Сборка не требуется. Офлайн-проверки используют подставные CLI, HTTP-ответы, ZIP-архивы и изолированный реестр. Они не отправляют запросы к моделям и не используют реальные credentials.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test-claude-ping.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test-codex-ping.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test-install.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test-ai-ping.ps1
```

Проверки Linux используют отдельные профили, подставные crontab/CLI, локальные архивы и HTTP-ответы:

```bash
python3 test-ubuntu.py
bash test-ubuntu.sh
```

[Сообщите о проблеме](https://github.com/dprytkov/ai-ping/issues), указав команду, версии Windows/CLI и вывод без секретных данных. Перед публикацией логов скройте email в строке `login`.

## Лицензия

[MIT](LICENSE) · © 2026 [dprytkov](https://github.com/dprytkov).

---

<p align="center"><a href="README.md">English version</a> · <a href="ai-ping.md">Подробная инструкция</a></p>
