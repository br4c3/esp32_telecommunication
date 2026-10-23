import {randomUUID} from 'node:crypto';
import {emptyTelemetry, mergeTelemetry, pruneTelemetry, telemetryView} from '../admin-web/shared/telemetry.js';
import {setCors, verifyToken} from './auth.js';

export const config = {maxDuration: 20};

export function createTelemetryHandler({read, write, secret, now = () => Date.now()}) {
  return async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    const corsAllowed = setCors(req, res);
    const reply = (status, data) => res.status(status).json({...data, serverNow: now()});
    if (req.method === 'OPTIONS') return corsAllowed ? res.status(204).end() : reply(403, {error: '허용되지 않은 출처예요.'});
    if (!secret || secret.length < 32) return reply(503, {error: '공유 서버 설정이 필요해요.'});
    const auth = verifyToken((req.headers.authorization || '').replace(/^Bearer /, ''), secret, now());
    if (!auth) return reply(401, {error: '유효한 공유 연결이 필요해요.'});
    if (!['GET', 'POST'].includes(req.method)) return reply(405, {error: '지원하지 않는 요청이에요.'});
    try {
      if (req.method === 'GET') {
        const {state} = await read(auth.room);
        return reply(200, {role: auth.role, room: auth.room, state: telemetryView(state, now())});
      }
      let input = req.body;
      if (typeof input === 'string') input = JSON.parse(input);
      if (!input || Buffer.byteLength(JSON.stringify(input)) > 64000) return reply(400, {error: '요청 형식을 확인해 주세요.'});
      if (auth.role === 'worker' && input.action !== 'upload') return reply(403, {error: '사용자 권한을 확인해 주세요.'});
      if (auth.role === 'admin' && !['acknowledge', 'notify'].includes(input.action)) return reply(403, {error: '관리자 권한을 확인해 주세요.'});
      for (let attempt = 0; attempt < 5; attempt++) {
        const stored = await read(auth.room);
        let next;
        if (auth.role === 'worker') {
          next = mergeTelemetry(stored.state, input, now());
        } else if (input.action === 'acknowledge') {
          const event = stored.state.events.find(item => item.id === input.eventId && ['help_requested', 'alert_created'].includes(item.type));
          if (!event) return reply(400, {error: '확인할 요청을 찾을 수 없어요.'});
          next = {...stored.state, acknowledgements: {...stored.state.acknowledgements, [event.id]: stored.state.acknowledgements[event.id] || {at: now()}}, updatedAt: now()};
        } else {
          const message = typeof input.message === 'string' ? input.message.trim() : '';
          if (!message || message.length > 300) return reply(400, {error: '알림 내용은 1~300자로 입력해 주세요.'});
          next = pruneTelemetry({...stored.state, notifications: [...(stored.state.notifications || []), {id: `notice-${randomUUID()}`, source: 'admin', at: now(), message}], updatedAt: now()}, now());
        }
        try {
          await write(auth.room, next, stored.etag);
          return reply(200, {role: auth.role, room: auth.room, state: telemetryView(next, now()), acceptedIds: auth.role === 'worker' ? input.events.map(event => event.id) : []});
        } catch (error) {
          if (!/precondition|already exists|already_exists/i.test(`${error.message} ${error.code}`)) throw error;
        }
      }
      return reply(409, {error: '다른 갱신을 반영 중이에요. 다시 시도해 주세요.'});
    } catch {
      return reply(503, {error: '공유 서버 연결에 실패했어요.'});
    }
  };
}

export {emptyTelemetry};
