'use strict';
const $ = id => document.getElementById(id);
let busy = false;
let timer;
let lastJob;
let ready = false;
const labels = {both: 'Claude и Codex', claude: 'Claude', codex: 'Codex'};

function error(message = '') {
  $('error').textContent = message;
  $('error').hidden = !message;
}

async function api(path, body) {
  const response = await fetch('api/' + path, body ? {
    method: 'POST', headers: {'Content-Type': 'application/json', 'X-AI-Ping': '1'},
    body: JSON.stringify(body)
  } : {cache: 'no-store'});
  if (response.status === 401) {
    window.location.reload();
    throw new Error('Сессия завершилась. Войдите в панель снова.');
  }
  let value;
  try {
    value = await response.json();
  } catch {
    throw new Error(response.status === 401 ? 'Войдите в панель заново: обновите страницу.' :
      response.status === 429 ? 'Слишком много запросов. Повторите через несколько секунд.' :
      'Сервис временно недоступен. Повторите обновление журнала.');
  }
  if (!response.ok) throw new Error(value.error || 'Сервис временно недоступен. Обновите страницу.');
  return value;
}

function renderJob(job) {
  busy = job?.state === 'running';
  $('run').disabled = busy || !ready;
  $('run').querySelector('span').textContent = busy ? 'Выполняется пинг…' : 'Запустить пинг';
  if (!job) return;
  $('job-status').textContent = busy ? 'Проверяем ' + labels[job.provider] + '…' :
    (job.exit_code === 0 ? 'Успешно' : job.exit_code === 75 ? 'Уже выполняется по расписанию' : 'Проверка завершилась с ошибкой');
  if (job.output) {
    $('empty').hidden = true;
    $('output').hidden = false;
    $('output').textContent = job.output;
    if (lastJob !== job.id && !busy) {
      $('output').classList.remove('complete');
      void $('output').offsetWidth;
      $('output').classList.add('complete');
      lastJob = job.id;
    }
  }
  clearTimeout(timer);
  if (busy) timer = setTimeout(refresh, 1800);
}

async function refresh() {
  $('refresh').disabled = true;
  try {
    const state = await api('status');
    ready = true;
    error();
    renderManagement(state);
    $('schedule').textContent = state.settings.enabled ? state.schedule.join(' · ') : 'Автоматический запуск отключён';
    $('schedule-zone').textContent = state.timezone;
    let next = state.next_run || '';
    if (next) { try { next = new Date(next).toLocaleString('ru-RU', {timeZone:state.timezone}); } catch { /* Display the server time for an unsupported browser timezone. */ } }
    $('next-run').textContent = next ? 'Следующий: ' + next : '';
    const log = $('log');
    const atBottom = log.scrollTop + log.clientHeight >= log.scrollHeight - 30;
    const changed = log.textContent !== state.log;
    log.textContent = state.log || 'Журнал пока пуст.';
    if (atBottom || !lastJob && changed) log.scrollTop = log.scrollHeight;
    $('updated').textContent = 'Обновлено в ' + new Date().toLocaleTimeString('ru-RU', {timeZone: 'Europe/Moscow'}) + ' МСК';
    renderJob(state.job);
  } catch (e) {
    error(e.message || 'Потеряна связь с сервером. Нажмите «Обновить журнал».');
    if (busy) timer = setTimeout(refresh, 4000);
  } finally {
    $('refresh').disabled = false;
  }
}

$('ping-form').addEventListener('submit', async event => {
  event.preventDefault();
  if (busy) return;
  const form = new FormData(event.currentTarget);
  const body = {provider: form.get('provider'),
    claude_model: $('claude-model').value.trim(), codex_model: $('codex-model').value.trim(),
    claude_account: $('claude-account').value, codex_account: $('codex-account').value};
  busy = true;
  $('run').disabled = true;
  error();
  try {
    const job = await api('run', body);
    $('output').hidden = true;
    $('empty').hidden = false;
    $('empty').querySelector('h3').textContent = 'Ожидаем ответ';
    $('empty').querySelector('p').textContent = 'Запрос выполняется. Обычно это занимает несколько секунд.';
    renderJob(job);
  } catch (e) {
    error(e.message || 'Не удалось отправить запрос.');
    busy = false;
    $('run').disabled = !ready;
  }
});
$('ping-form').addEventListener('change', event => {
  if (event.target.name !== 'provider') return;
  for (const provider of ['claude', 'codex']) {
    $(provider + '-model').disabled = event.target.value !== 'both' && event.target.value !== provider;
    $(provider + '-account').disabled = event.target.value !== 'both' && event.target.value !== provider;
  }
});
$('refresh').addEventListener('click', refresh);
$('logout').addEventListener('click', async () => {
  $('logout').disabled = true;
  try { await api('logout', {}); window.location.reload(); }
  catch (e) { error(e.message); $('logout').disabled = false; }
});
refresh();
