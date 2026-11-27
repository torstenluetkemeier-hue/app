// Einfache JSON-Dateiablage für den Prototyp.
// Für den Produktivbetrieb durch eine Datenbank ersetzen (siehe KONZEPT.md).

import fs from 'node:fs';
import path from 'node:path';
import { defaultConfig } from './core/defaults.js';

export class Store {
  constructor(dir) {
    this.dir = dir;
    fs.mkdirSync(dir, { recursive: true });
    this.configFile = path.join(dir, 'config.json');
    this.messagesFile = path.join(dir, 'nachrichten.json');
    this.config = this.read(this.configFile, defaultConfig);
    this.nachrichten = this.read(this.messagesFile, () => []);
  }

  read(file, fallback) {
    try {
      return JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch {
      const v = fallback();
      this.write(file, v);
      return v;
    }
  }

  write(file, value) {
    const tmp = file + '.tmp';
    fs.writeFileSync(tmp, JSON.stringify(value, null, 2));
    fs.renameSync(tmp, file);
  }

  saveConfig() { this.write(this.configFile, this.config); }
  saveMessages() { this.write(this.messagesFile, this.nachrichten); }

  user(id) { return this.config.users.find((u) => u.id === id) || null; }
}
