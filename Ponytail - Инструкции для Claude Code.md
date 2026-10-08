---
title: "Экономия токенов в Claude Code: RTK, Ponytail, Caveman, Headroom — практические инструкции"
tags: [ai-tech, claude-code, token-saving, ai-agents, rtk, headroom, caveman, ponytail]
aliases: ["Claude Code: экономия токенов", "Ponytail для Claude Code"]
processed_at: 2026-10-06
---

# Экономия токенов в Claude Code — практические инструкции

Дополнение к заметке [[Ponytail - Оптимизация ИИ-агентов и экономия токенов]]. Там описаны Gemini 3.8 Flash и GPT-6 Astra, а Claude Code упомянут только в тегах. Здесь собрано то, что настраивается в самом Claude Code. Сведения актуальны на октябрь 2026.

---

## 0. Поправки к исходной заметке (сверено 2026-10-06)

| Утверждение в заметке | Как на самом деле |
| :--- | :--- |
| RTK чистит вывод «через AST-фильтрацию», «0 overhead» | Работает через парсеры вывода конкретных команд: фильтрует, группирует, обрезает и схлопывает повторы. Накладные расходы небольшие, но не нулевые. 60–90% — это экономия на **выводе одной команды**, а не на всём счёте. Репозиторий: [rtk-ai/rtk](https://github.com/rtk-ai/rtk) |
| RTK перехватывает всё | Перехватываются только вызовы **Bash**. Встроенные Read / Grep / Glob в Claude Code проходят мимо хука |
| Headroom: CCR = «Compressed Cache Retrieval», сокращает вход на 40–50% | В README CCR расшифровывается как **Cached Content Retrieval**. Для агентов-кодеров заявлено **~20%**, для JSON — 60–95% |
| Headroom — «просто прокси» | `headroom wrap claude` дополнительно **регистрирует MCP-сервер Serena в `~/.claude.json`**. Анонимный beacon включён по умолчанию (`HEADROOM_BEACON=off`). Волатильный контент может не попадать в prefix cache провайдера |
| Caveman сокращает только output | В нынешней версии есть и прокси для **входа** (заявлено −33% входных токенов за сессию). Скрытые reasoning-токены Caveman **не уменьшает**: ими управляет effort |
| Caveman снижает TTFT | Не снижает: время до первого токена зависит от входа и reasoning. Сокращается только общее время генерации ответа |
| Ponytail: −54% кода, −20% токенов, +27% скорость | Это бенчмарк автора: **Claude Haiku 4.5**, один репозиторий FastAPI + React, 12 задач, n=4. Переносить эти цифры на Astra или Flash без проверки нельзя |
| Gemini 3.8 Flash: окно 1M–2M+ | **1M** токенов. Вышла 2026-09-02, стоит примерно $0.375 / $1.88 за 1M токенов (AI Studio) |
| GPT-6 Astra: окно «большое, но лимитированное» | **1.05M** токенов (до 922K на вход). Вышла 2026-09-03, стоит $10 / $50, cached input — $1. После **272K** вход стоит 2×, выход 1.5×. Есть лимиты на 5 часов и на неделю, в Codex — «searchable notes» вместо обычной компактизации |
| «Каждый вызов инструмента перечитывает историю и сжигает лимит» | Заметка не учитывает **prompt caching**: перечитанный префикс тарифицируется примерно по 10% цены. Дорого обходится то, что **инвалидирует кэш**: смена модели или инструментов посреди сессии, правки CLAUDE.md, MCP с меняющимися схемами |
| «Подписка живёт в 3–4 раза дольше» | Ничем не подтверждено. Проценты разных инструментов не перемножаются, потому что режут одни и те же входные токены |
| Headroom для Flash «бессмысленен из-за огромного окна» | Вывод верный, обоснование нет. Шум в контексте вредит при любом размере окна. Headroom не нужен по другой причине: для дешёвой модели сложность прокси не окупается |

---

## 1. Приоритеты для Claude Code

Порядок выбран по соотношению «эффект / риск / сложность»:

1. **Встроенные средства Claude Code**: ничего не стоят и ничего не ломают (раздел 2).
2. **RTK**: самый безопасный внешний инструмент, он только фильтрует вывод (раздел 3).
3. **Ponytail**: дисциплина минимального diff'а (раздел 4).
4. **Caveman**: по желанию, только для ответов в чате (раздел 5).
5. **Headroom**: только для длинных сессий с тяжёлыми JSON, логами или MCP. Подключать после аудита (раздел 6).

Не включайте всё одновременно. Каждый скилл и каждый MCP-сервер сам занимает контекст, а два прокси в одной цепочке (Headroom и прокси Caveman) мешают друг другу и затрудняют отладку.

---

## 2. Встроенные рычаги Claude Code (без сторонних инструментов)

- **`/context`**: показывает, на что уходит окно (системный промпт, инструменты, MCP, память, история). Начинайте с него.
- **`/mcp`**: отключите серверы, которые не нужны в текущем проекте. Схемы инструментов попадают в каждый запрос.
- **`/clear`** между несвязанными задачами, **`/compact <на чём сосредоточиться>`** перед переходом к новому этапу в той же задаче.
- **`/model`** и уровень effort: для рутинных правок берите модель полегче и effort ниже, тяжёлую модель оставьте для архитектуры и отладки.
- **Не меняйте модель, инструменты и CLAUDE.md посреди длинной сессии**, иначе сбрасывается prompt cache.
- **Субагенты** подходят для широкого поиска по коду: их промежуточный вывод не попадает в основной контекст. Но каждый субагент стартует с нуля, поэтому для мелких задач они дороже.
- **CLAUDE.md** должен быть коротким: он загружается в каждую сессию. Подробности выносите в отдельные файлы и ссылайтесь на них.
- **Запрет на чтение мусора**: добавьте `deny` для `Read(...)` на `node_modules`, `dist`, логи и дампы в `.claude/settings.json` (`permissions.deny`).

---

## 3. RTK — установка и проверка

```bash
rtk --version          # убедиться, что это rtk-ai/rtk, а не Rust Type Kit
rtk init -g            # глобальный хук для Claude Code (Bash-вызовы → rtk ...)
rtk gain               # статистика экономии
rtk discover           # какие команды прошли мимо RTK
```

- На Windows хук работает из cmd, PowerShell и Windows Terminal (начиная с v0.37.2).
- Некоторые фильтры вызывают `rg`, поэтому ripgrep должен быть в `PATH`.
- Если нужен сырой вывод (например, полный стек ошибки), используйте `rtk proxy <cmd>`.
- RTK не трогает встроенные Read / Grep / Glob, так что экономия касается только shell.

---

## 4. Ponytail — установка

```text
/plugin marketplace add DietrichGebert/ponytail
/plugin install ponytail@ponytail
```

Если плагин ставить не хочется, достаточно вставить в CLAUDE.md проекта короткую выжимку (раздел 7). Обычно она даёт тот же эффект при меньшем расходе контекста.

Проверка: дайте задачу вида «добавь флаг в конфиг» и посмотрите на `git diff --stat`. Diff должен затронуть 1–2 файла и не добавить новых зависимостей.

---

## 5. Caveman — по желанию

```bash
claude plugin marketplace add JuliusBrussee/caveman && claude plugin install caveman@caveman
```

- Подходит, если раздражает многословие в чате. Коммит-сообщения, README и документацию пишите **без** него: глобальный CLAUDE.md требует подробных коммитов, и Caveman будет с этим конфликтовать.
- Прокси Caveman для входа не сочетайте с Headroom: выберите что-то одно.

---

## 6. Headroom — только после аудита

```bash
headroom wrap claude
```

Перед использованием:

- Проверьте `~/.claude.json`: в нём появится MCP-сервер **Serena**. Если он не нужен, удалите его через `/mcp` или вручную.
- Отключите телеметрию: `HEADROOM_BEACON=off`.
- Через локальный прокси проходят **все запросы вместе с токеном авторизации**. Ставьте его только из официального репозитория и проверяйте версию.
- Сравните `/context` и расход за одинаковую задачу с Headroom и без него. При обычной работе с кодом выигрыш около 20%, а не 40–50%.

---

## 7. Блок для CLAUDE.md (скопировать в проект)

```markdown
## Token & Code Discipline

- Before writing code, walk the ladder: not needed? → reuse existing code in repo → stdlib → native platform feature → already-installed dependency → one-liner → minimal new code. Never add a dependency without asking.
- Minimal diff: touch only what the task needs. No drive-by refactors, renames, or reformatting.
- Prefix shell commands with `rtk`; use `rtk proxy <cmd>` only when raw output is required.
- Do not read `node_modules/`, build outputs, lockfiles, or large logs unless the task is about them; grep first, then read the relevant range.
- Chat replies: lead with the result, no preamble or recap. Commit messages and docs follow their own detailed format.
- Use subagents only for broad multi-file searches; do small lookups inline.
```

---

## 8. Как измерять эффект

- Сравнивайте **одну и ту же задачу** до и после изменений, минимум 3 прогона: разброс у агентов большой.
- Смотрите `/context` в начале сессии (постоянные накладные расходы), `rtk gain` (shell) и расход лимита в `/usage` (или в настройках аккаунта).
- Включайте инструменты по одному и проверяйте эффект каждого. Если выигрыш меньше 5%, инструмент не стоит потраченного на него контекста.

---

## Источники

- [rtk-ai/rtk](https://github.com/rtk-ai/rtk) · [DietrichGebert/ponytail](https://github.com/DietrichGebert/ponytail) · [headroomlabs-ai/headroom](https://github.com/headroomlabs-ai/headroom) · [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman)
- [GPT-6 Astra в Codex CLI — окно, цены, порог 272K](https://codex.danielvaughan.com/2026/09/04/gpt-6-astra-codex-cli-integration-guide-critical-cyber-threshold/)
- [OpenAI Help: лимиты GPT-6 Astra в Work и Codex](https://help.openai.com/en/articles/20001516-managing-usage-with-gpt-6-astra-in-work-and-codex)
- [Gemini 3.8 Flash — цены](https://pricepertoken.com/pricing-page/model/google-gemini-3.8-flash)
- [Implicator: GPT-6 Astra и изменение лимитов Claude Code с 14.09.2026](https://www.implicator.ai/gpt-6-astra-claude-code-heaviest-users-limits-drop.md)
