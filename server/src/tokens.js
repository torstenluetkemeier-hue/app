import crypto from 'node:crypto';

const b64url = (buf) => Buffer.from(buf).toString('base64url');

export function signAccessToken({ userId, email }, secret, ttlSeconds, now = Date.now()) {
  const header = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const iat = Math.floor(now / 1000);
  const payload = b64url(JSON.stringify({ sub: userId, email, iat, exp: iat + ttlSeconds, typ: 'access' }));
  const signature = crypto.createHmac('sha256', secret).update(`${header}.${payload}`).digest('base64url');
  return `${header}.${payload}.${signature}`;
}

/** Gibt die Claims zurück oder null, wenn das Token ungültig oder abgelaufen ist. */
export function verifyAccessToken(token, secret, now = Date.now()) {
  if (typeof token !== 'string') return null;
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  const [header, payload, signature] = parts;
  const expected = crypto.createHmac('sha256', secret).update(`${header}.${payload}`).digest();
  const given = Buffer.from(signature, 'base64url');
  if (given.length !== expected.length || !crypto.timingSafeEqual(given, expected)) return null;
  try {
    const head = JSON.parse(Buffer.from(header, 'base64url').toString('utf8'));
    if (head.alg !== 'HS256') return null;
    const claims = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
    if (claims.typ !== 'access' || typeof claims.exp !== 'number') return null;
    if (claims.exp * 1000 <= now) return null;
    return claims;
  } catch {
    return null;
  }
}

export function generateRefreshToken() {
  return crypto.randomBytes(32).toString('base64url');
}

export function hashToken(token) {
  return crypto.createHash('sha256').update(token).digest('hex');
}
