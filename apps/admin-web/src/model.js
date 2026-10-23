export const labels = {
  session_started: '측정 연결', baseline_registered: '개인 기준 등록',
  baseline_failed: '기준 등록 중단', alert_created: '압력 완화 안내',
  alert_acknowledged: '사용자 안내 확인', relief_armed: '완화 확인 준비',
  relief_completed: '완화 조건 충족', relief_interrupted: '완화 확인 중단',
  data_lost: '관측 공백', help_requested: '도움 요청',
  sharing_started: '관리자 공유 시작', sharing_stopped: '관리자 공유 중지',
};
export const channelNames = ['왼쪽 앞', '오른쪽 앞', '왼쪽 뒤', '오른쪽 뒤', '꼬리뼈 쪽'];
export const channelIds = ['L1', 'R1', 'L2', 'R2', 'C1'];
export function currentView(state, online, now) {
  const s = state?.snapshot;
  const age = s ? now - s.at : Infinity;
  const fresh = !!(online && s?.connected && s.quality !== 'unavailable' && age >= -300000 && age < 15000);
  if (!s) return {fresh: false, tone: 'neutral', title: '사용자 연결을 기다리고 있어요', guidance: '공유가 시작되면 현재 상태가 여기에 표시돼요.', values: null};
  if (!fresh) return {fresh: false, tone: 'neutral', title: '최근 측정을 확인해 주세요', guidance: '현재 상태를 판단할 수 없어요. 사용자 앱과 방석 연결을 확인해 주세요.', values: null};
  if (s.quality === 'unloaded') return {fresh, tone: 'neutral', title: '좌면 부하가 없어요', guidance: '좌면 부하가 감지되지 않아요. 사용자의 착석 여부를 확인해 주세요.', values: s.values};
  if (!s.baseline) return {fresh, tone: 'neutral', title: '개인 기준이 필요해요', guidance: '사용자 앱에서 편안하게 앉은 상태로 개인 기준을 등록해 주세요.', values: s.values};
  if (s.bias.length) return {fresh, tone: 'caution', title: '압력 완화를 확인해 주세요', guidance: `${s.bias.map(id => channelNames[channelIds.indexOf(id)]).join(', ')} 부하가 개인 기준보다 높게 이어지고 있어요.`, values: s.values};
  return {fresh, tone: 'normal', title: '개인 기준에 가까워요', guidance: '개인 착석 기준과 비슷한 압력 분포를 보이고 있어요.', values: s.values};
}
export function pendingRequests(state) {
  return (state?.events || []).filter(e => ['help_requested', 'alert_created'].includes(e.type) && !state.acknowledgements[e.id]).reverse();
}
export function filterEvents(events, filter, search) {
  const types = {help: ['help_requested'], alert: ['alert_created', 'alert_acknowledged'], relief: ['relief_completed']};
  const text = search.trim().toLocaleLowerCase();
  return [...events].reverse().filter(e => (!types[filter] || types[filter].includes(e.type)) && `${labels[e.type] || e.type} ${e.detail}`.toLocaleLowerCase().includes(text));
}
export function normalizeUserCode(value) {
  const code = value.trim();
  if (!/^[a-zA-Z0-9_-]{16,80}$/.test(code)) throw Error('사용자 코드를 확인해 주세요.');
  return code;
}
// Explicit UI preview only. Never uploaded to the sensor API.
export function previewState(now) {
  return {snapshot: {source: 'demo', at: now, device: '미리보기 방석', connected: true, quality: 'seated', values: [620, 1100, 580, 1240, 680], baseline: [650, 650, 650, 650, 550], bias: ['R1', 'R2']}, acknowledgements: {}, events: [
    {id: 'preview-baseline', type: 'baseline_registered', at: now - 32 * 60000, detail: '편안한 착석 상태에서 개인 기준을 등록했어요.'},
    {id: 'preview-relief', type: 'relief_completed', at: now - 18 * 60000, detail: '선택 부위의 부하 감소가 20초 동안 유지됐어요.'},
    {id: 'preview-alert', type: 'alert_created', at: now - 3 * 60000, detail: '오른쪽 부하 증가가 이어지고 있어요.'},
    {id: 'preview-help', type: 'help_requested', at: now - 60000, detail: '사용자가 도움을 요청했어요.'},
  ]};
}
