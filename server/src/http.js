export class HttpError extends Error {
  constructor(status, code, message, extra = undefined) {
    super(message);
    this.status = status;
    this.code = code;
    this.extra = extra;
  }
}

const SECURITY_HEADERS = {
  'Content-Type': 'application/json; charset=utf-8',
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
};

export function sendJson(res, status, body) {
  const json = body === undefined ? '' : JSON.stringify(body);
  res.writeHead(status, { ...SECURITY_HEADERS, 'Content-Length': Buffer.byteLength(json) });
  res.end(json);
}

export function sendError(res, err) {
  if (err instanceof HttpError) {
    sendJson(res, err.status, { error: { code: err.code, message: err.message, ...err.extra } });
    return;
  }
  console.error('[server] Unerwarteter Fehler:', err);
  sendJson(res, 500, { error: { code: 'internal_error', message: 'Interner Serverfehler.' } });
}

export function readJson(req, maxBytes) {
  return new Promise((resolve, reject) => {
    const type = req.headers['content-type'] ?? '';
    if (!type.toLowerCase().startsWith('application/json')) {
      reject(new HttpError(415, 'unsupported_media_type', 'Content-Type muss application/json sein.'));
      req.resume();
      return;
    }
    let size = 0;
    const chunks = [];
    let aborted = false;
    req.on('data', (chunk) => {
      if (aborted) return;
      size += chunk.length;
      if (size > maxBytes) {
        aborted = true;
        reject(new HttpError(413, 'payload_too_large', 'Anfrage ist zu groß.'));
        req.resume();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (aborted) return;
      try {
        const text = Buffer.concat(chunks).toString('utf8');
        const value = text.length ? JSON.parse(text) : {};
        if (value === null || typeof value !== 'object' || Array.isArray(value)) {
          throw new Error('not an object');
        }
        resolve(value);
      } catch {
        reject(new HttpError(400, 'invalid_json', 'Ungültiges JSON.'));
      }
    });
    req.on('error', reject);
  });
}

export function clientIp(req, trustProxy) {
  if (trustProxy) {
    const forwarded = req.headers['x-forwarded-for'];
    if (typeof forwarded === 'string' && forwarded.length) return forwarded.split(',')[0].trim();
  }
  return req.socket.remoteAddress ?? 'unknown';
}
