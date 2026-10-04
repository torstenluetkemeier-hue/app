import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createRateLimiter } from '../src/rateLimit.js';

test('Ratelimiter blockiert nach Limit und setzt nach Fenster zurück', () => {
  let t = 0;
  const limiter = createRateLimiter({ limit: 2, windowMs: 1000, now: () => t });
  assert.equal(limiter.hit('a'), 0);
  assert.equal(limiter.hit('a'), 0);
  assert.equal(limiter.hit('a'), 1);
  assert.equal(limiter.hit('b'), 0);
  t = 1000;
  assert.equal(limiter.hit('a'), 0);
});
