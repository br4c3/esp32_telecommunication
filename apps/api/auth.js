import {createHmac, timingSafeEqual} from 'node:crypto';

export function issueToken(secret, room, role, expiresAt) {
  const payload = Buffer.from(JSON.stringify({v: 1, room, role, exp: expiresAt})).toString('base64url');
  return `${payload}.${createHmac('sha256', secret).update(payload).digest('base64url')}`;
}

export function verifyToken(token, secret, now = Date.now()) {
  if (typeof token !== 'string' || token.length > 1024) return null;
  const parts = token.split('.');
  if (parts.length !== 2) return null;
  const expected = createHmac('sha256', secret).update(parts[0]).digest('base64url');
  if (parts[1].length !== expected.length || !timingSafeEqual(Buffer.from(parts[1]), Buffer.from(expected))) return null;
  try {
    const data = JSON.parse(Buffer.from(parts[0], 'base64url'));
    return data.v === 1 && /^[a-zA-Z0-9_-]{16,80}$/.test(data.room) &&
      ['worker', 'admin'].includes(data.role) && Number.isSafeInteger(data.exp) && data.exp > now
      ? data : null;
  } catch {
    return null;
  }
}

export function setCors(req, res) {
  const allowed = process.env.ADMIN_ORIGIN;
  if (allowed && req.headers.origin === allowed) {
    res.setHeader('Access-Control-Allow-Origin', allowed);
    res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Vary', 'Origin');
  }
  return !req.headers.origin || req.headers.origin === allowed;
}
