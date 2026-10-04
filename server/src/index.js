import http from 'node:http';
import { createApp } from './app.js';
import { loadConfig } from './config.js';
import { openDatabase } from './db.js';

const config = loadConfig();
const db = openDatabase(config.databasePath);
const server = http.createServer(createApp({ config, db }));
server.requestTimeout = 30_000;
server.headersTimeout = 15_000;

server.listen(config.port, config.host, () => {
  console.log(`[server] Wochenleicht-Server läuft auf http://${config.host}:${config.port}`);
});

function shutdown(signal) {
  console.log(`[server] ${signal} empfangen, fahre herunter …`);
  server.close(() => {
    db.close();
    process.exit(0);
  });
  setTimeout(() => process.exit(1), 10_000).unref();
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
