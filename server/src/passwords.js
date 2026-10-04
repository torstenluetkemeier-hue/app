import crypto from 'node:crypto';
import { promisify } from 'node:util';

const scrypt = promisify(crypto.scrypt);

const PARAMS = { N: 16384, r: 8, p: 1 };
const KEY_LENGTH = 64;

export const PASSWORD_MIN_LENGTH = 8;
export const PASSWORD_MAX_LENGTH = 128;

export async function hashPassword(password) {
  const salt = crypto.randomBytes(16);
  const key = await scrypt(password.normalize('NFKC'), salt, KEY_LENGTH, { ...PARAMS, maxmem: 64 * 1024 * 1024 });
  return ['scrypt', PARAMS.N, PARAMS.r, PARAMS.p, salt.toString('base64'), key.toString('base64')].join('$');
}

export async function verifyPassword(password, stored) {
  const parts = String(stored).split('$');
  if (parts.length !== 6 || parts[0] !== 'scrypt') return false;
  const [, N, r, p, saltB64, keyB64] = parts;
  const expected = Buffer.from(keyB64, 'base64');
  const key = await scrypt(password.normalize('NFKC'), Buffer.from(saltB64, 'base64'), expected.length, {
    N: Number(N),
    r: Number(r),
    p: Number(p),
    maxmem: 64 * 1024 * 1024,
  });
  return crypto.timingSafeEqual(key, expected);
}

/** Liefert eine Fehlermeldung oder null, wenn das Passwort den Regeln entspricht. */
export function validatePassword(password) {
  if (typeof password !== 'string') return 'Passwort fehlt.';
  if (password.length < PASSWORD_MIN_LENGTH) return `Passwort muss mindestens ${PASSWORD_MIN_LENGTH} Zeichen haben.`;
  if (password.length > PASSWORD_MAX_LENGTH) return `Passwort darf höchstens ${PASSWORD_MAX_LENGTH} Zeichen haben.`;
  if (!/[A-Za-zÄÖÜäöüß]/.test(password) || !/[0-9]/.test(password)) {
    return 'Passwort muss mindestens einen Buchstaben und eine Ziffer enthalten.';
  }
  return null;
}

// Vorberechneter Hash, damit Logins mit unbekannter E-Mail gleich lange dauern (kein User-Enumeration-Timing).
let dummyHashPromise;
export function dummyHash() {
  dummyHashPromise ??= hashPassword('dummy-password-0');
  return dummyHashPromise;
}
