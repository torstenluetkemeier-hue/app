import crypto from 'node:crypto';

export function loadConfig(env = process.env) {
  const production = env.NODE_ENV === 'production';
  let jwtSecret = env.JWT_SECRET;
  if (!jwtSecret) {
    if (production) {
      throw new Error('JWT_SECRET muss in Produktion gesetzt sein (mind. 32 Zeichen).');
    }
    jwtSecret = crypto.randomBytes(32).toString('hex');
    console.warn('[config] JWT_SECRET nicht gesetzt – verwende zufälliges Entwicklungs-Secret. Tokens werden beim Neustart ungültig.');
  }
  if (jwtSecret.length < 32) {
    throw new Error('JWT_SECRET muss mindestens 32 Zeichen lang sein.');
  }

  return {
    production,
    port: Number(env.PORT ?? 8080),
    host: env.HOST ?? '0.0.0.0',
    databasePath: env.DATABASE_PATH ?? './data/wochenleicht.sqlite',
    jwtSecret,
    accessTokenTtlSeconds: Number(env.ACCESS_TOKEN_TTL_SECONDS ?? 15 * 60),
    refreshTokenTtlSeconds: Number(env.REFRESH_TOKEN_TTL_SECONDS ?? 60 * 24 * 60 * 60),
    maxBodyBytes: Number(env.MAX_BODY_BYTES ?? 2 * 1024 * 1024),
    trustProxy: env.TRUST_PROXY === 'true',
    // Anzahl erlaubter Login/Registrierungs-Versuche pro IP im Zeitfenster
    authRateLimit: Number(env.AUTH_RATE_LIMIT ?? 20),
    authRateWindowMs: Number(env.AUTH_RATE_WINDOW_MS ?? 15 * 60 * 1000),
  };
}
