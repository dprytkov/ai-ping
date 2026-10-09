'use strict';
const field = id => document.getElementById(id);
let panelAccounts = [];
let panelSettings;
let managementLoaded = false;
let settingsDirty = false;
let accountSignature = '';

function notice(id, text = '') { field(id).textContent = text; field(id).hidden = !text; }
function providerLabel(provider) { return provider === 'claude' ? 'Claude' : 'Codex'; }
function showView(key) {
  for (const name of ['run', 'settings', 'accounts']) {
    field('view-' + name).hidden = name !== key;
    field('tab-' + name).setAttribute('aria-selected', String(name === key));
    field('tab-' + name).tabIndex = name === key ? 0 : -1;
  }
}
for (const tab of document.querySelectorAll('[data-view]')) {
  tab.addEventListener('click', () => showView(tab.dataset.view));
  tab.addEventListener('keydown', event => {
    if (!['ArrowLeft', 'ArrowRight'].includes(event.key)) return;
    const tabs = [...document.querySelectorAll('[data-view]')];
    const target = tabs[(tabs.indexOf(tab) + (event.key === 'ArrowRight' ? 1 : 2)) % 3];
    event.preventDefault(); target.click(); target.focus();
  });
}

function options(element, provider, desired) {
  const before = element.value;
  const accounts = panelAccounts.filter(a => a.provider === provider);
  element.replaceChildren(...accounts.map(a => new Option(a.name, a.id)));
  const choice = desired || before;
  element.value = accounts.some(a => a.id === choice) ? choice : accounts[0]?.id || '';
}

function accountDetails(account) {
  const parts = [providerLabel(account.provider), account.email || (account.builtin ? 'Серверная авторизация' : 'Импортирован из файла')];
  if (!account.authorized) parts.push('Нет авторизации');
  if (account.expires_at) {
    parts.push(account.expires_at * 1000 <= Date.now() ? 'Авторизация истекла' :
      'До ' + new Date(account.expires_at * 1000).toLocaleString('ru-RU', {timeZone: 'Europe/Moscow'}));
  }
  return parts.join(' · ');
}

function selectedAccountNotes() {
  for (const provider of ['claude', 'codex']) {
    const account = panelAccounts.find(a => a.id === field(provider + '-account').value);
    field(provider + '-auth').textContent = account ? accountDetails(account) : 'Выберите аккаунт';
  }
  const claude = panelAccounts.find(a => a.id === field('claude-account').value);
  field('limit-note').textContent = claude && !claude.limits_available ?
    'У выбранного Claude setup-token: пинги доступны, статистика лимитов недоступна.' :
    'Лимиты и сведения об аккаунте появятся в выводе пинга, если доступны для этой авторизации.';
}

function drawAccounts() {
  field('accounts-list').replaceChildren(...panelAccounts.map(account => {
    const row = document.createElement('div'); row.className = 'account-row';
    const name = document.createElement('div'); name.className = 'account-name'; name.textContent = account.name;
    const details = document.createElement('p'); details.className = 'account-meta'; details.textContent = accountDetails(account);
    const actions = document.createElement('div'); actions.className = 'form-actions';
    const update = document.createElement('button'); update.type = 'button'; update.className = 'secondary'; update.textContent = 'Обновить авторизацию';
    update.addEventListener('click', () => editAccount(account)); actions.append(update);
    if (!account.builtin) {
      const remove = document.createElement('button'); remove.type = 'button'; remove.className = 'secondary danger'; remove.textContent = 'Удалить';
      remove.addEventListener('click', async () => {
        if (!window.confirm('Удалить «' + account.name + '»? Аккаунт будет исключён из расписания.')) return;
        remove.disabled = true;
        try { renderManagement(await api('accounts/delete', {id: account.id})); notice('account-message', 'Аккаунт удалён.'); }
        catch (e) { notice('account-error', e.message); remove.disabled = false; }
      }); actions.append(remove);
    }
    row.append(name, details, actions); return row;
  }));
}

function drawScheduleAccounts(selected) {
  field('scheduled-accounts').replaceChildren(...panelAccounts.map(account => {
    const label = document.createElement('label'); label.className = 'check';
    const checkbox = document.createElement('input'); checkbox.type = 'checkbox'; checkbox.value = account.id;
    checkbox.checked = selected.includes(account.id);
    const name = document.createElement('span'); name.textContent = account.name;
    label.append(checkbox, name); return label;
  }));
}

function renderManagement(state, force = false) {
  if (!state.settings || !state.accounts) return;
  panelSettings = state.settings; panelAccounts = state.accounts;
  const changed = accountSignature !== JSON.stringify(panelAccounts);
  const selected = settingsDirty && !force ? [...field('scheduled-accounts').querySelectorAll('input:checked')].map(el => el.value) : panelSettings.scheduled_accounts;
  for (const provider of ['claude', 'codex']) {
    options(field(provider + '-account'), provider, !managementLoaded || force ? panelSettings.default_accounts[provider] : undefined);
    options(field('default-' + provider + '-account'), provider, !settingsDirty || force ? panelSettings.default_accounts[provider] : undefined);
    if (!managementLoaded || force) field(provider + '-model').value = panelSettings.models[provider];
    if (!settingsDirty || force) field('default-' + provider + '-model').value = panelSettings.models[provider];
  }
  if (!settingsDirty || force) {
    field('schedule-enabled').checked = panelSettings.enabled;
    field('schedule-times').value = panelSettings.times.join(', ');
    field('schedule-timezone').value = panelSettings.timezone;
  }
  if (changed || !managementLoaded || force) { drawAccounts(); drawScheduleAccounts(selected); }
  if (force) settingsDirty = false;
  accountSignature = JSON.stringify(panelAccounts); managementLoaded = true;
  selectedAccountNotes();
}

field('settings-form').addEventListener('input', () => { settingsDirty = true; notice('settings-message', 'Есть несохранённые изменения.'); });
field('settings-form').addEventListener('submit', async event => {
  event.preventDefault(); field('save-settings').disabled = true; notice('settings-error');
  const settings = {
    enabled: field('schedule-enabled').checked,
    timezone: field('schedule-timezone').value.trim(),
    times: field('schedule-times').value.split(',').map(value => value.trim()).filter(Boolean),
    models: {claude: field('default-claude-model').value.trim(), codex: field('default-codex-model').value.trim()},
    default_accounts: {claude: field('default-claude-account').value, codex: field('default-codex-account').value},
    scheduled_accounts: [...field('scheduled-accounts').querySelectorAll('input:checked')].map(el => el.value)
  };
  try { renderManagement(await api('settings', settings), true); notice('settings-message', 'Расписание сохранено.'); await refresh(); }
  catch (e) { notice('settings-error', e.message); }
  finally { field('save-settings').disabled = false; }
});

function providerHelp() {
  const claude = field('account-provider').value === 'claude';
  field('auth-path').textContent = claude ? '%USERPROFILE%\\.claude\\.credentials.json' : '%USERPROFILE%\\.codex\\auth.json';
  field('setup-token-field').hidden = !claude;
}
function resetAccountForm() {
  field('account-form').reset(); field('account-id').value = '';
  field('account-provider').disabled = false; field('import-title').textContent = 'Добавить из Windows';
  field('import-account').textContent = 'Добавить аккаунт'; field('cancel-account-edit').hidden = true;
  providerHelp();
}
function editAccount(account) {
  resetAccountForm(); field('account-id').value = account.id;
  field('account-provider').value = account.provider; field('account-provider').disabled = true;
  field('account-name').value = account.name; field('import-title').textContent = 'Обновить авторизацию';
  field('import-account').textContent = 'Сохранить авторизацию'; field('cancel-account-edit').hidden = false;
  notice('account-error'); notice('account-message'); providerHelp(); field('account-name').focus();
}
field('account-provider').addEventListener('change', () => {
  if (field('account-name').value.startsWith('Windows · ')) field('account-name').value = 'Windows · ' + providerLabel(field('account-provider').value);
  providerHelp();
});
field('cancel-account-edit').addEventListener('click', resetAccountForm);

function subscriptionFields(provider, value) {
  const key = provider === 'claude' ? 'claudeAiOauth' : 'tokens';
  const source = value?.[key] || value;
  const access = provider === 'claude' ? 'accessToken' : 'access_token';
  if (!source || typeof source[access] !== 'string' || !source[access]) throw new Error('Файл не содержит авторизацию ' + providerLabel(provider) + '.');
  const kept = {[access]: source[access]};
  for (const property of provider === 'claude' ? ['scopes', 'expiresAt'] : ['account_id', 'id_token']) {
    if (source[property] !== undefined && source[property] !== null) kept[property] = source[property];
  }
  return {[key]: kept};
}

field('account-form').addEventListener('submit', async event => {
  event.preventDefault(); field('import-account').disabled = true; notice('account-error'); notice('account-message');
  try {
    const provider = field('account-provider').value;
    const file = field('auth-file').files[0];
    let authorization;
    if (file) {
      if (file.size > 32768) throw new Error('Файл слишком большой: максимум 32 КБ.');
      try { authorization = JSON.parse((await file.text()).replace(/^\uFEFF/, '')); }
      catch { throw new Error('Не удалось прочитать JSON авторизации. Выберите исходный файл Claude или Codex.'); }
    } else if (provider === 'claude' && field('setup-token').value.trim()) {
      authorization = {claudeAiOauth: {accessToken: field('setup-token').value.trim(), scopes: ['user:inference']}};
    } else { throw new Error('Выберите файл авторизации из Windows' + (provider === 'claude' ? ' или укажите setup-token.' : '.')); }
    const body = {provider, name: field('account-name').value.trim(), authorization: subscriptionFields(provider, authorization)};
    if (field('account-id').value) body.id = field('account-id').value;
    const state = await api('accounts/import', body);
    renderManagement(state); resetAccountForm(); notice('account-message', 'Авторизация сохранена. Аккаунт доступен для запуска.');
  } catch (e) { notice('account-error', e.message || 'Не удалось импортировать авторизацию.'); }
  finally { field('import-account').disabled = false; }
});
for (const provider of ['claude', 'codex']) field(provider + '-account').addEventListener('change', selectedAccountNotes);
