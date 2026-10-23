import {pressureField} from '/admin/shared/sensor.js';
import {CHANNELS} from '/admin/shared/layout.js';
import {labels, channelIds, channelNames, currentView, pendingRequests, filterEvents, normalizeUserCode, previewState} from './model.js';

const $ = selector => document.querySelector(selector);
const $$ = selector => [...document.querySelectorAll(selector)];
const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;'}[c]));
const time = at => new Date(at).toLocaleString('ko-KR', {month:'numeric', day:'numeric', hour:'2-digit', minute:'2-digit', hour12:false});
const storage = {
  get(key) { try {return sessionStorage.getItem(key);} catch {return null;} },
  set(key, value) { try {sessionStorage.setItem(key, value);} catch { /* Session can still run without persistence. */ } },
  remove(key) { try {sessionStorage.removeItem(key);} catch { /* No persistent token exists in this context. */ } },
};
let token = new URLSearchParams(location.hash.slice(1)).get('key') || storage.get('seat-care-admin') || '';
let endpoint = storage.get('seat-care-admin-endpoint') || `${location.origin}/api/telemetry`;
if (location.hash) history.replaceState(null, '', location.pathname + location.search);
let state = null, room = '', online = false, demo = false, busy = false, page = 'overview', filter = 'all', search = '';
let timer, abort, generation = 0, offset = 0, lastSuccess = 0;
const signatures = new Map();
$('#today').textContent = new Date().toLocaleDateString('ko-KR', {year:'numeric', month:'long', day:'numeric', weekday:'long'});
$('#sensor-points').innerHTML = channelIds.map((id, i) => `<span class="point" title="${channelNames[i]}" style="left:${CHANNELS[id].x * 100}%;top:${CHANNELS[id].y * 100}%"></span>`).join('');

function showPage(next) {
  page = next;
  $$('.page').forEach(el => el.hidden = el.id !== `${page}-page`);
  $$('[data-page]').forEach(el => {
    el.classList.toggle('active', el.dataset.page === page);
    if (el.dataset.page === page) el.setAttribute('aria-current', 'page');
    else el.removeAttribute('aria-current');
  });
  $('#breadcrumb').textContent = {overview:'현재 상태', records:'기록', settings:'설정'}[page];
  paint();
  $('#main').focus({preventScroll: true});
  window.scrollTo({top: 0});
}
function setFilter(next) {
  filter = next;
  $$('[data-filter]').forEach(el => {
    const selected = el.dataset.filter === filter;
    el.classList.toggle('selected', selected);
    el.setAttribute('aria-pressed', String(selected));
  });
  paint();
}
function draw(values) {
  const canvas = $('#map'), ctx = canvas.getContext('2d');
  ctx.fillStyle = '#E7EFE6'; ctx.fillRect(0, 0, 240, 300);
  if (values) {
    pressureField(values, 60, 48).forEach((row, y) => row.forEach((value, x) => {
      const p = Math.max(0, Math.min(1, value / 3200));
      const start = p < .5 ? [231,239,230] : [53,107,82];
      const end = p < .5 ? [53,107,82] : [166,91,25];
      const t = p < .5 ? p * 2 : (p - .5) * 2;
      ctx.fillStyle = `rgb(${start.map((v, i) => Math.round(v + (end[i] - v) * t)).join(',')})`;
      ctx.fillRect(x * 5, y * 5, 5, 5);
    }));
  }
  $('#map-empty').hidden = !!values;
  $('#sensor-points').hidden = !values;
  canvas.setAttribute('aria-label', values ? channelNames.map((label, i) => `${label} ${Math.round(values[i])}`).join(', ') : '현재 센서값 없음');
}
function eventsHtml(events, allowActions = true) {
  if (!events.length) return '<li class="empty">표시할 기록이 없어요.</li>';
  return events.map(e => {
    const ack = state?.acknowledgements[e.id];
    const action = allowActions && ['help_requested', 'alert_created'].includes(e.type)
      ? ack ? `<span class="ack">확인 완료<time>${time(ack.at)}</time></span>`
        : `<button data-ack="${escape(e.id)}" ${busy || (!demo && !online) ? 'disabled' : ''}>${demo ? '예시 확인' : '안내 확인'}</button>`
      : '';
    return `<li><div class="event-content"><time datetime="${new Date(e.at).toISOString()}">${time(e.at)}</time><strong class="${e.type === 'help_requested' ? 'help-label' : ''}">${escape(labels[e.type] || e.type)}</strong><p>${escape(e.detail)}</p></div>${action}</li>`;
  }).join('');
}
function updateList(selector, events, actions) {
  const html = eventsHtml(events, actions);
  if (signatures.get(selector) !== html) {$(selector).innerHTML = html; signatures.set(selector, html);}
}
function paint() {
  const now = Date.now() + offset;
  if (demo && state) state.snapshot.at = now;
  const view = currentView(state, demo || online, now), s = state?.snapshot;
  const pending = pendingRequests(state), events = state?.events || [];
  const helpCount = pending.filter(e => e.type === 'help_requested').length;
  $('#join').hidden = demo || !!state;
  $('#demo-banner').hidden = !demo;
  $('#connection').textContent = demo ? '예시 데이터' : online ? '공유 서버 연결됨' : token ? '공유 연결 확인 중' : '공유 연결 전';
  $('#connection').className = `connection${demo ? ' caution' : online ? ' live' : ''}`;
  $('#refresh').disabled = busy || (!token && !demo);
  $('#disconnect').disabled = !token && !demo;
  $('#room-label').textContent = demo ? '미리보기 공유방' : room ? `공유방 ${room.slice(0, 8)}` : '연결된 공유방 없음';
  $('#summary-state').textContent = demo ? '예시 연결' : !s ? '연결 대기' : view.fresh ? '수신 중' : '수신 중단';
  $('#summary-device').textContent = s?.device || '사용자 앱에서 공유를 켜 주세요';
  $('#help-count').textContent = state ? helpCount : '—';
  $('#completed').textContent = state ? events.filter(e => e.type === 'relief_completed').length : '—';
  $('#nav-count').textContent = helpCount;
  $('#nav-count').hidden = helpCount === 0;
  $('#data-kind').textContent = demo ? '예시 데이터' : view.fresh ? '실제 센서' : '수신 대기';
  $('#state-title').textContent = view.title;
  $('#guidance').textContent = view.guidance;
  $('.current-panel').dataset.tone = view.tone;
  $('#state-mark').textContent = view.tone === 'caution' ? '!' : view.tone === 'normal' ? '✓' : '—';
  $('#last-reading').textContent = s ? time(s.at) : '—';
  const signature = JSON.stringify(view.values);
  if (signatures.get('pressure') !== signature) {
    draw(view.values); signatures.set('pressure', signature);
    $('#readings').innerHTML = channelNames.map((name, i) => `<div><dt>${name}<small>${channelIds[i]}</small></dt><dd>${view.values ? Math.round(view.values[i]) : '—'}</dd></div>`).join('');
  }
  updateList('#requests', pending.slice(0, 2), true);
  updateList('#recent-events', [...events].reverse().slice(0, 3), false);
  const filtered = filterEvents(events, filter, search);
  updateList('#events', filtered, true);
  $('#records-meta').textContent = `${filtered.length}개 기록 · 최근 90일, 최대 2,000개${demo ? ' · 미리보기' : ''}`;
  $('#settings-connection').textContent = demo ? '미리보기 · 실제 센서 미연결' : online ? '공유 서버 연결됨' : '연결 전 또는 수신 중단';
  $('#settings-device').textContent = s?.device || '—';
  const notificationDisabled = busy || demo || !online;
  $('#overview-notify-submit').disabled = notificationDisabled;
  $('#notify-submit').disabled = notificationDisabled;
}
function fail(error) {
  online = false;
  $('#error').textContent = error.name === 'TimeoutError' ? '서버 응답이 늦어요. 잠시 후 다시 시도해 주세요.' : error.message || '공유 서버에 연결하지 못했어요.';
  $('#error').hidden = false;
}
function stop() {
  generation++; clearTimeout(timer); abort?.abort(); busy = false;
}
async function refresh(body) {
  clearTimeout(timer);
  if (demo) {paint(); return;}
  if (!token || document.hidden || busy) return;
  const current = generation, requestToken = token;
  busy = true;
  const controller = new AbortController(); abort = controller;
  const timeout = setTimeout(() => controller.abort(), 12000);
  paint();
  try {
    const res = await fetch(endpoint, {
      method: body ? 'POST' : 'GET', redirect: 'error', cache: 'no-store',
      headers: {Authorization: `Bearer ${requestToken}`, ...(body ? {'Content-Type': 'application/json'} : {})},
      body: body ? JSON.stringify(body) : undefined, signal: controller.signal,
    });
    const data = await res.json();
    if (current !== generation) return;
    if (!res.ok) throw Error(data.error || '공유 서버에 연결하지 못했어요.');
    if (data.role !== 'admin') throw Error('관리자용 초대 링크를 사용해 주세요.');
    if (room && room !== data.room) throw Error('공유방이 달라요. 초대 링크를 다시 확인해 주세요.');
    room = data.room; state = data.state; offset = data.serverNow - Date.now();
    online = true; lastSuccess = Date.now();
    storage.set('seat-care-admin', requestToken);
    storage.set('seat-care-admin-endpoint', endpoint);
    $('#error').hidden = true;
    if (body?.action === 'notify') $('#notice').textContent = '사용자에게 알림을 보냈어요.';
    else if (body) $('#notice').textContent = '관리자 확인을 기록했어요.';
  } catch (error) {
    if (current === generation) fail(error.name === 'AbortError' ? Error('연결 시간이 초과됐어요. 다시 시도해 주세요.') : error);
  } finally {
    clearTimeout(timeout);
    if (current === generation) {
      busy = false; paint();
      if (token && !document.hidden) timer = setTimeout(() => refresh(), 5000);
    }
  }
}
function leave() {
  stop(); token = ''; state = null; room = ''; demo = false; online = false; offset = 0;
  storage.remove('seat-care-admin'); storage.remove('seat-care-admin-endpoint'); $('#error').hidden = true; signatures.clear();
  const url = new URL(location.href); url.searchParams.delete('preview');
  history.replaceState(null, '', url.pathname + url.search);
  showPage('overview'); $('#invite').focus();
}
$('#join-form').addEventListener('submit', e => {
  e.preventDefault();
  connectWithCode($('#invite').value);
});
async function connectWithCode(value) {
  stop(); busy = true; paint();
  try {
    const code = normalizeUserCode(value);
    const connectEndpoint = new URL('/api/admin-connect', location.origin);
    const res = await fetch(connectEndpoint, {method: 'POST', cache: 'no-store', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({code})});
    const data = await res.json();
    if (!res.ok || !data.token || data.room !== code) throw Error(data.error || '사용자 코드로 연결하지 못했어요.');
    token = data.token; endpoint = new URL('/api/telemetry', connectEndpoint.origin).href;
    room = ''; state = null; demo = false; online = false;
    storage.remove('seat-care-admin'); storage.remove('seat-care-admin-endpoint');
    $('#invite').value = ''; busy = false; await refresh();
  } catch (error) {busy = false; fail(error); paint();}
}
function startPreview() {
  stop(); token = ''; storage.remove('seat-care-admin'); demo = true; offset = 0;
  state = previewState(Date.now()); $('#error').hidden = true; signatures.clear(); paint();
}
$('#preview').onclick = startPreview;
$('#exit-demo').onclick = leave;
$('#disconnect').onclick = leave;
$('#refresh').onclick = () => refresh();
$$('[data-page]').forEach(button => button.onclick = () => showPage(button.dataset.page));
$$('[data-filter]').forEach(button => button.onclick = () => setFilter(button.dataset.filter));
$('#search').oninput = e => {search = e.target.value; paint();};
async function sendUserNotification(input, count) {
  const message = input.value.trim();
  if (!message || busy || (!demo && !online)) return;
  if (demo) {
    $('#notice').textContent = '미리보기에서는 실제 알림을 보내지 않아요.';
    return;
  }
  await refresh({action: 'notify', message});
  if (online) {input.value = ''; count.textContent = '0 / 300';}
}
[
  ['#overview-notify-form', '#overview-notify-message', '#overview-notify-count'],
  ['#notify-form', '#notify-message', '#notify-count'],
].forEach(([formSelector, inputSelector, countSelector]) => {
  const form = $(formSelector), input = $(inputSelector), count = $(countSelector);
  input.oninput = () => {count.textContent = `${input.value.length} / 300`;};
  form.addEventListener('submit', e => {
    e.preventDefault();
    sendUserNotification(input, count);
  });
});
$$('[data-notify-message]').forEach(button => {
  button.onclick = () => {
    const form = button.closest('form');
    const input = form.querySelector('textarea');
    input.value = button.dataset.notifyMessage;
    input.dispatchEvent(new Event('input'));
    input.focus();
  };
});
$('#view-help').onclick = () => {setFilter('help'); showPage('records');};
$('#view-requests').onclick = () => {setFilter('all'); showPage('records');};
$$('[data-open-records]').forEach(button => button.onclick = () => {setFilter('all'); showPage('records');});
document.addEventListener('click', e => {
  const button = e.target.closest('[data-ack]');
  if (!button || button.disabled) return;
  if (demo) {
    state.acknowledgements[button.dataset.ack] = {at: Date.now()};
    $('#notice').textContent = '미리보기 요청을 확인했어요. 실제 요청을 처리하지 않았어요.';
    paint();
  } else refresh({action: 'acknowledge', eventId: button.dataset.ack});
});
$('#text-size').onclick = () => {
  const on = document.documentElement.classList.toggle('large-text');
  $('#text-size').setAttribute('aria-checked', String(on));
  storage.set('seat-care-large-text', String(on));
};
if (storage.get('seat-care-large-text') === 'true') {
  document.documentElement.classList.add('large-text'); $('#text-size').setAttribute('aria-checked', 'true');
}
setInterval(() => {
  if (Date.now() - lastSuccess > 15000) online = false;
  if (!document.hidden) paint();
}, 1000);
document.addEventListener('visibilitychange', () => {
  if (document.hidden) {stop(); online = false; paint();} else refresh();
});
if (!token && new URLSearchParams(location.search).get('preview') === '1') startPreview();
else {paint(); refresh();}
