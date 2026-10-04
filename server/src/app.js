import crypto from 'node:crypto';
import { createRepository } from './db.js';
import { HttpError, clientIp, readJson, sendError, sendJson } from './http.js';
import { dummyHash, hashPassword, validatePassword, verifyPassword } from './passwords.js';
import { createRateLimiter } from './rateLimit.js';
import { generateRefreshToken, hashToken, signAccessToken, verifyAccessToken } from './tokens.js';

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

export function normalizeEmail(email) {
  if (typeof email !== 'string') return null;
  const normalized = email.trim().toLowerCase();
  if (normalized.length > 254 || !EMAIL_PATTERN.test(normalized)) return null;
  return normalized;
}

export function createApp({ config, db, now = () => Date.now() }) {
  const repo = createRepository(db);
  const authLimiter = createRateLimiter({ limit: config.authRateLimit, windowMs: config.authRateWindowMs, now });

  function publicUser(user) {
    return { id: user.id, email: user.email, createdAt: new Date(user.created_at).toISOString() };
  }

  function issueTokens(user, familyId = crypto.randomUUID()) {
    const t = now();
    const refreshToken = generateRefreshToken();
    repo.storeRefreshToken({
      tokenHash: hashToken(refreshToken),
      userId: user.id,
      familyId,
      expiresAt: t + config.refreshTokenTtlSeconds * 1000,
      createdAt: t,
    });
    return {
      accessToken: signAccessToken({ userId: user.id, email: user.email }, config.jwtSecret, config.accessTokenTtlSeconds, t),
      refreshToken,
      expiresIn: config.accessTokenTtlSeconds,
      tokenType: 'Bearer',
      user: publicUser(user),
    };
  }

  function rateLimit(req, scope) {
    const retryAfter = authLimiter.hit(`${scope}:${clientIp(req, config.trustProxy)}`);
    if (retryAfter > 0) {
      throw new HttpError(429, 'rate_limited', 'Zu viele Versuche. Bitte später erneut versuchen.', { retryAfter });
    }
  }

  function authenticate(req) {
    const header = req.headers.authorization ?? '';
    const match = /^Bearer (.+)$/.exec(header);
    const claims = match ? verifyAccessToken(match[1], config.jwtSecret, now()) : null;
    if (!claims) throw new HttpError(401, 'unauthorized', 'Nicht angemeldet oder Sitzung abgelaufen.');
    const user = repo.findUserById(claims.sub);
    if (!user) throw new HttpError(401, 'unauthorized', 'Benutzer existiert nicht mehr.');
    return user;
  }

  const routes = {
    'GET /health': async () => ({ status: 200, body: { status: 'ok' } }),

    'POST /v1/auth/register': async (req) => {
      rateLimit(req, 'register');
      const body = await readJson(req, config.maxBodyBytes);
      const email = normalizeEmail(body.email);
      if (!email) throw new HttpError(400, 'invalid_email', 'Bitte eine gültige E-Mail-Adresse angeben.');
      const passwordError = validatePassword(body.password);
      if (passwordError) throw new HttpError(400, 'weak_password', passwordError);
      if (repo.findUserByEmail(email)) {
        throw new HttpError(409, 'email_taken', 'Für diese E-Mail-Adresse existiert bereits ein Konto.');
      }
      const user = { id: crypto.randomUUID(), email, created_at: now() };
      const passwordHash = await hashPassword(body.password);
      try {
        repo.createUser({ id: user.id, email, passwordHash, createdAt: user.created_at });
      } catch (err) {
        if (String(err.message).includes('UNIQUE')) {
          throw new HttpError(409, 'email_taken', 'Für diese E-Mail-Adresse existiert bereits ein Konto.');
        }
        throw err;
      }
      return { status: 201, body: issueTokens(user) };
    },

    'POST /v1/auth/login': async (req) => {
      rateLimit(req, 'login');
      const body = await readJson(req, config.maxBodyBytes);
      const email = normalizeEmail(body.email);
      const password = typeof body.password === 'string' ? body.password : '';
      const user = email ? repo.findUserByEmail(email) : undefined;
      const ok = await verifyPassword(password, user ? user.password_hash : await dummyHash());
      if (!user || !ok) throw new HttpError(401, 'invalid_credentials', 'E-Mail oder Passwort ist falsch.');
      return { status: 200, body: issueTokens(user) };
    },

    'POST /v1/auth/refresh': async (req) => {
      rateLimit(req, 'refresh');
      const body = await readJson(req, config.maxBodyBytes);
      if (typeof body.refreshToken !== 'string') {
        throw new HttpError(400, 'invalid_request', 'refreshToken fehlt.');
      }
      const tokenHash = hashToken(body.refreshToken);
      const stored = repo.findRefreshToken(tokenHash);
      const t = now();
      if (!stored || stored.expires_at <= t) {
        throw new HttpError(401, 'invalid_refresh_token', 'Sitzung abgelaufen. Bitte erneut anmelden.');
      }
      // Wiederverwendung eines bereits rotierten Tokens deutet auf Diebstahl hin → ganze Familie sperren.
      if (stored.revoked_at !== null || !repo.revokeRefreshToken(tokenHash, t)) {
        repo.revokeTokenFamily(stored.family_id, t);
        throw new HttpError(401, 'invalid_refresh_token', 'Sitzung abgelaufen. Bitte erneut anmelden.');
      }
      const user = repo.findUserById(stored.user_id);
      if (!user) throw new HttpError(401, 'invalid_refresh_token', 'Benutzer existiert nicht mehr.');
      return { status: 200, body: issueTokens(user, stored.family_id) };
    },

    'POST /v1/auth/logout': async (req) => {
      const body = await readJson(req, config.maxBodyBytes);
      if (typeof body.refreshToken === 'string') {
        const stored = repo.findRefreshToken(hashToken(body.refreshToken));
        if (stored) repo.revokeTokenFamily(stored.family_id, now());
      }
      return { status: 204 };
    },

    'GET /v1/me': async (req) => ({ status: 200, body: { user: publicUser(authenticate(req)) } }),

    'DELETE /v1/me': async (req) => {
      const user = authenticate(req);
      repo.deleteUser(user.id);
      return { status: 204 };
    },

    'PUT /v1/me/password': async (req) => {
      const user = authenticate(req);
      const body = await readJson(req, config.maxBodyBytes);
      const ok = await verifyPassword(String(body.currentPassword ?? ''), user.password_hash);
      if (!ok) throw new HttpError(401, 'invalid_credentials', 'Aktuelles Passwort ist falsch.');
      const passwordError = validatePassword(body.newPassword);
      if (passwordError) throw new HttpError(400, 'weak_password', passwordError);
      repo.updatePassword(user.id, await hashPassword(body.newPassword));
      // Alle anderen Sitzungen abmelden, frische Tokens für dieses Gerät ausgeben.
      repo.revokeAllTokensForUser(user.id, now());
      return { status: 200, body: issueTokens(user) };
    },

    'GET /v1/data': async (req) => {
      const user = authenticate(req);
      const data = repo.getUserData(user.id);
      if (!data) return { status: 200, body: { version: 0, payload: null, updatedAt: null } };
      return { status: 200, body: { ...data, updatedAt: new Date(data.updatedAt).toISOString() } };
    },

    'PUT /v1/data': async (req) => {
      const user = authenticate(req);
      const body = await readJson(req, config.maxBodyBytes);
      if (!Number.isInteger(body.baseVersion) || body.baseVersion < 0) {
        throw new HttpError(400, 'invalid_request', 'baseVersion muss eine ganze Zahl ≥ 0 sein.');
      }
      if (body.payload === null || typeof body.payload !== 'object') {
        throw new HttpError(400, 'invalid_request', 'payload muss ein Objekt sein.');
      }
      const t = now();
      const version = repo.putUserData(user.id, body.baseVersion, body.payload, t);
      if (version === null) {
        const current = repo.getUserData(user.id);
        throw new HttpError(409, 'version_conflict', 'Daten wurden auf einem anderen Gerät geändert.', {
          current: current && { ...current, updatedAt: new Date(current.updatedAt).toISOString() },
        });
      }
      return { status: 200, body: { version, updatedAt: new Date(t).toISOString() } };
    },
  };

  let lastPurge = 0;

  return async function handler(req, res) {
    try {
      const t = now();
      if (t - lastPurge > 60 * 60 * 1000) {
        lastPurge = t;
        repo.purgeExpiredTokens(t);
      }
      const url = new URL(req.url, 'http://localhost');
      const route = routes[`${req.method} ${url.pathname}`];
      if (!route) {
        const known = Object.keys(routes).some((key) => key.endsWith(` ${url.pathname}`));
        throw known
          ? new HttpError(405, 'method_not_allowed', 'Methode nicht erlaubt.')
          : new HttpError(404, 'not_found', 'Nicht gefunden.');
      }
      const { status, body } = await route(req);
      sendJson(res, status, body);
    } catch (err) {
      sendError(res, err);
    }
  };
}
