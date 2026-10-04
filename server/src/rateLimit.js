/** Einfacher In-Memory-Ratelimiter (Fixed Window). Für mehrere Instanzen durch Redis o. Ä. ersetzen. */
export function createRateLimiter({ limit, windowMs, now = () => Date.now() }) {
  const buckets = new Map();

  function sweep(t) {
    for (const [key, bucket] of buckets) {
      if (bucket.resetAt <= t) buckets.delete(key);
    }
  }

  return {
    /** Gibt die Sekunden bis zum Reset zurück, wenn das Limit überschritten ist, sonst 0. */
    hit(key) {
      const t = now();
      if (buckets.size > 10_000) sweep(t);
      let bucket = buckets.get(key);
      if (!bucket || bucket.resetAt <= t) {
        bucket = { count: 0, resetAt: t + windowMs };
        buckets.set(key, bucket);
      }
      bucket.count += 1;
      return bucket.count > limit ? Math.ceil((bucket.resetAt - t) / 1000) : 0;
    },
  };
}
