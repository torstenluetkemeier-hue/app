import fs from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

const MIGRATIONS = [
  `CREATE TABLE users (
     id TEXT PRIMARY KEY,
     email TEXT NOT NULL UNIQUE,
     password_hash TEXT NOT NULL,
     created_at INTEGER NOT NULL
   );
   CREATE TABLE refresh_tokens (
     token_hash TEXT PRIMARY KEY,
     user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
     family_id TEXT NOT NULL,
     expires_at INTEGER NOT NULL,
     revoked_at INTEGER,
     created_at INTEGER NOT NULL
   );
   CREATE INDEX idx_refresh_user ON refresh_tokens(user_id);
   CREATE TABLE user_data (
     user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
     version INTEGER NOT NULL,
     payload TEXT NOT NULL,
     updated_at INTEGER NOT NULL
   );`,
];

export function openDatabase(databasePath) {
  if (databasePath !== ':memory:') {
    fs.mkdirSync(path.dirname(path.resolve(databasePath)), { recursive: true });
  }
  const db = new DatabaseSync(databasePath);
  db.exec('PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;');
  migrate(db);
  return db;
}

function migrate(db) {
  const current = db.prepare('PRAGMA user_version').get().user_version;
  for (let i = current; i < MIGRATIONS.length; i++) {
    db.exec('BEGIN');
    try {
      db.exec(MIGRATIONS[i]);
      db.exec(`PRAGMA user_version = ${i + 1}`);
      db.exec('COMMIT');
    } catch (err) {
      db.exec('ROLLBACK');
      throw err;
    }
  }
}

export function createRepository(db) {
  const stmts = {
    insertUser: db.prepare('INSERT INTO users (id, email, password_hash, created_at) VALUES (?, ?, ?, ?)'),
    userByEmail: db.prepare('SELECT * FROM users WHERE email = ?'),
    userById: db.prepare('SELECT * FROM users WHERE id = ?'),
    updatePassword: db.prepare('UPDATE users SET password_hash = ? WHERE id = ?'),
    deleteUser: db.prepare('DELETE FROM users WHERE id = ?'),
    insertRefresh: db.prepare(
      'INSERT INTO refresh_tokens (token_hash, user_id, family_id, expires_at, created_at) VALUES (?, ?, ?, ?, ?)'
    ),
    refreshByHash: db.prepare('SELECT * FROM refresh_tokens WHERE token_hash = ?'),
    revokeRefresh: db.prepare('UPDATE refresh_tokens SET revoked_at = ? WHERE token_hash = ? AND revoked_at IS NULL'),
    revokeFamily: db.prepare('UPDATE refresh_tokens SET revoked_at = ? WHERE family_id = ? AND revoked_at IS NULL'),
    revokeAllForUser: db.prepare('UPDATE refresh_tokens SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL'),
    purgeExpired: db.prepare('DELETE FROM refresh_tokens WHERE expires_at < ?'),
    dataByUser: db.prepare('SELECT version, payload, updated_at FROM user_data WHERE user_id = ?'),
    insertData: db.prepare('INSERT INTO user_data (user_id, version, payload, updated_at) VALUES (?, 1, ?, ?)'),
    updateData: db.prepare(
      'UPDATE user_data SET version = version + 1, payload = ?, updated_at = ? WHERE user_id = ? AND version = ?'
    ),
  };

  return {
    createUser({ id, email, passwordHash, createdAt }) {
      stmts.insertUser.run(id, email, passwordHash, createdAt);
    },
    findUserByEmail: (email) => stmts.userByEmail.get(email),
    findUserById: (id) => stmts.userById.get(id),
    updatePassword: (id, hash) => stmts.updatePassword.run(hash, id),
    deleteUser: (id) => stmts.deleteUser.run(id),

    storeRefreshToken({ tokenHash, userId, familyId, expiresAt, createdAt }) {
      stmts.insertRefresh.run(tokenHash, userId, familyId, expiresAt, createdAt);
    },
    findRefreshToken: (hash) => stmts.refreshByHash.get(hash),
    /** Gibt true zurück, wenn genau dieser Aufruf das Token widerrufen hat (Schutz vor Race Conditions). */
    revokeRefreshToken: (hash, now) => stmts.revokeRefresh.run(now, hash).changes === 1,
    revokeTokenFamily: (familyId, now) => stmts.revokeFamily.run(now, familyId),
    revokeAllTokensForUser: (userId, now) => stmts.revokeAllForUser.run(now, userId),
    purgeExpiredTokens: (now) => stmts.purgeExpired.run(now),

    getUserData(userId) {
      const row = stmts.dataByUser.get(userId);
      if (!row) return null;
      return { version: row.version, payload: JSON.parse(row.payload), updatedAt: row.updated_at };
    },
    /**
     * Optimistische Nebenläufigkeit: baseVersion muss der aktuellen Version entsprechen
     * (0 = noch keine Daten vorhanden). Gibt die neue Version zurück oder null bei Konflikt.
     */
    putUserData(userId, baseVersion, payload, now) {
      const json = JSON.stringify(payload);
      if (baseVersion === 0) {
        try {
          stmts.insertData.run(userId, json, now);
          return 1;
        } catch (err) {
          if (String(err.message).includes('UNIQUE') || String(err.message).includes('PRIMARY KEY')) return null;
          throw err;
        }
      }
      const result = stmts.updateData.run(json, now, userId, baseVersion);
      return result.changes === 1 ? baseVersion + 1 : null;
    },
  };
}
