'use strict';
const form = document.getElementById('login-form');
const button = document.getElementById('login-button');
const error = document.getElementById('login-error');
form.addEventListener('submit', async event => {
  event.preventDefault();
  button.disabled = true;
  button.textContent = 'Входим…';
  error.hidden = true;
  try {
    const response = await fetch('api/login', {
      method: 'POST', headers: {'Content-Type': 'application/json', 'X-AI-Ping': '1'},
      body: JSON.stringify({username: form.elements.username.value.trim(), password: form.elements.password.value})
    });
    let result;
    try { result = await response.json(); }
    catch { throw new Error('Не удалось войти. Повторите через несколько секунд.'); }
    if (!response.ok) throw new Error(result.error || 'Не удалось войти. Повторите попытку.');
    form.elements.password.value = '';
    window.location.replace('./');
  } catch (e) {
    error.textContent = e.message || 'Потеряна связь с сервером. Повторите попытку.';
    error.hidden = false;
    button.disabled = false;
    button.textContent = 'Войти';
  }
});
