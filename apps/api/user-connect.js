import {randomBytes} from 'node:crypto';
import {issueToken, setCors} from './auth.js';

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  const corsAllowed = setCors(req, res);
  if (req.method === 'OPTIONS') return corsAllowed ? res.status(204).end() : res.status(403).end();
  if (req.method !== 'POST') return res.status(405).json({error: '지원하지 않는 요청이에요.'});
  const secret = process.env.SENSOR_SHARE_SECRET;
  if (!secret || secret.length < 32) return res.status(503).json({error: '공유 서버 설정이 필요해요.'});
  const room = randomBytes(18).toString('base64url');
  const expiresAt = Date.now() + 30 * 86400000;
  return res.status(200).json({
    room,
    token: issueToken(secret, room, 'worker', expiresAt),
    endpoint: '/api/telemetry',
    expiresAt,
  });
}
