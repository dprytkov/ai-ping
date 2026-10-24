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

Требования: Linux x86_64 (включая WSL), Bash, Python 3.8+, cron с `crontab`, `flock`, coreutils, awk, grep, curl, tar, gzip и tzdata. Включите службу cron своего дистрибутива. Для расписания в WSL дистрибутив должен оставаться запущенным.

1. Запустите установщик от пользователя, которому будет принадлежать расписание, без sudo:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/dprytkov/ai-ping/main/install.sh | bash
   ```

2. Выберите первое время запуска и провайдера. Для Codex откройте показанную ссылку и введите одноразовый код для входа в ChatGPT. Установщик скачает официальный CLI, проверит SHA-256 и создаст отдельную серверную сессию. После нового входа выполняется один короткий проверочный пинг; повторная установка использует сохранённую сессию. Для Claude без CLI вставьте токен, полученный командой `claude setup-token` на Windows; он разрешает пинги, но не получение статистики лимитов.

Откройте новый терминал и выполните `codex-ping` или `ai-ping`. Для Codex не нужны копирование токенов и отдельный таймер: перед пингом проверяется срок локального токена, а официальный CLI обновляет его только при необходимости. Веб-панель необязательна и читает ту же серверную сессию.

Из клона или ZIP: `bash ai-ping-setup.sh --start 06:00 --provider both`. По умолчанию пинги идут в **06:00, 11:01, 16:02, 21:03 Europe/Moscow**, независимо от часового пояса сервера. Для настройки используйте `--start`, `--provider`, `--timezone`, `--claude-model`, `--codex-model`. Повтор установки обновляет скрипты и расписание, сохраняя чужие cron-задания. Новый вход требует подтверждения в браузере даже при неинтерактивном запуске установщика.

Команды и Python-модули устанавливаются в `~/.local/bin`. Отдельный Codex CLI находится в `~/.local/lib/ai-ping/codex`, вне PATH; единственный активный файл его авторизации — `~/.local/state/ai-ping/codex/auth.json` с правами `600`. Перед установкой уберите переопределение `CODEX_HOME`; личные CLI-профили не перезаписываются. Ранее импортированные профили сохраняются, но автоматически не обновляются.

```bash
codex-ping gpt-5.6-luna
crontab -l
tail -n 40 ~/.local/state/ai-ping/ai-ping.log
```

Если сессия отозвана, выполните `python3 ~/.local/bin/ai-ping.py --codex-login` и подтвердите новый код. Для отключения расписания удалите блок AI-PING через `crontab -e`. [Хранение авторизации, восстановление и миграция](codex-auth.md).

## Веб-панель

Дополнительная [веб-панель](web/README.md) позволяет вручную запускать Claude/Codex, выбирать аккаунт, импортировать авторизацию из Windows, управлять общим расписанием и читать существующий журнал AI Ping. Она использует установленные Linux-команды и общую блокировку cron. Вход — через форму с паролем и сессионную cookie; новые аккаунты не включаются в расписание автоматически. Поддерживаются до 12 аккаунтов, включая два встроенных серверных.

Панель разворачивается отдельно на Ubuntu/Debian с AI Ping для root, авторизацией обоих провайдеров, существующей cron-задачей и HTTPS vhost Nginx. Обычные установщики её не разворачивают. Из каталога `web` на целевом сервере:

```sh
sudo python3 deploy.py --host panel.example.com --vhost /etc/nginx/sites-enabled/panel.conf
```

Замените пример домена и путь своим vhost. Развёртывание сохраняет резервные копии, существующие аккаунты/настройки панели и проверяет HTTPS-вход без запросов к моделям. Начальное расписание — **06:00, 11:01, 16:02, 21:03 Europe/Moscow**; часы, модели и участников можно изменить через панель. После её установки расписанием управляют настройки панели. После обновления основной Linux-установки повторите развёртывание панели для восстановления cron-wrapper. Требования, импорт Windows, хранение и откат описаны в [инструкции панели](web/README.md).

## Требования Windows

- Windows с **Windows PowerShell 5.1** и доступом к интернету.
- `curl.exe` и `tar.exe` в `PATH` для установки из интернета.
- CLI нужного провайдера со входом по подписке и доступом к выбранной модели.
- Claude Code с поддержкой `--safe-mode` и `--effort`; проверено с версией **2.1.289**.

**Вход:** запустите `claude` и выполните `/login` либо запустите `codex login`. Установщики не устанавливают CLI и не выполняют вход; Linux-установщик может импортировать авторизацию из Windows при отсутствии CLI. Windows-установщик не создаёт задачи по расписанию; Linux-установщик создаёт расписание cron, описанное выше.

В Windows сообщение `FAIL: Claude authentication failed` означает, что нужно выполнить `claude auth login`, завершить вход в браузере и повторить `claude-ping`. Отсутствие OAuth-токена для статистики лимитов обозначается отдельно; переустановка AI Ping не восстанавливает сессию Claude.

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

В Windows оба пинга запрашивают статистику лимитов и после неудачного запроса. Если провайдер сообщает об исчерпании лимита, выводится обычное сообщение `LIMIT: quota exhausted. Try again after reset.`, затем `LIMITS` с остатком в процентах и серверным временем сброса. Другие ошибки сохраняют `FAIL`; при недоступности статистики выводится предупреждение. Код выхода остаётся `1`, поскольку пинг не прошёл.

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

Интернет-загрузчики сохраняют файлы на диск перед запуском локального установщика. Авторизация остаётся в профиле пользователя и исключена из Git. Linux Codex предпочитает отдельную сессию `~/.local/state/ai-ping/codex/auth.json`; явный `CODEX_HOME` выбирает прежний CLI-профиль. Без отдельной сессии сохраняется прежняя работа CLI/импортированных credentials. Claude использует свой CLI-профиль либо импортированную авторизацию AI Ping. Не публикуйте auth-файлы и refresh-токены.

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
python3 test-linux.py
bash test-linux.sh
```

Офлайн-проверки панели (Linux):

```sh
cd web
python3 -m unittest -v test_web.py test_profiles.py test_deploy.py
sh -n ai-ping-run.sh
```

[Сообщите о проблеме](https://github.com/dprytkov/ai-ping/issues), указав команду, версии Windows/CLI и вывод без секретных данных. Перед публикацией логов скройте email в строке `login`.

## Лицензия

[MIT](LICENSE) · © 2026 [dprytkov](https://github.com/dprytkov).

---

<p align="center"><a href="README.md">English version</a> · <a href="ai-ping.md">Подробная инструкция</a></p>
