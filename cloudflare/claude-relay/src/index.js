// Struis Claude relay: App Attest で正規の Struis アプリだと確かめた要求だけを Anthropic の Messages API に中継する。
// 要求処理は relay.js、状態は RelayState(Durable Object・SQLite)。
import { DurableObject } from 'cloudflare:workers';
import { handle } from './relay.js';

export default {
  async fetch(request, env) {
    return handle(request, env);
  },
};

/** 名前ごとに 1 つ(チャレンジ・端末の鍵・使用回数)。 */
export class RelayState extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec('CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT NOT NULL)');
  }

  get(k) {
    const row = this.sql.exec('SELECT v FROM kv WHERE k = ?', k).toArray()[0];
    return row ? JSON.parse(row.v) : null;
  }

  set(k, v) {
    this.sql.exec('INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v', k, JSON.stringify(v));
  }

  async putChallenge(expiresAt) {
    this.set('challenge', { expiresAt });
    await this.ctx.storage.setAlarm(expiresAt + 1000);
  }

  takeChallenge(now) {
    const value = this.get('challenge');
    this.sql.exec('DELETE FROM kv WHERE k = ?', 'challenge');
    return Boolean(value && value.expiresAt >= now);
  }

  putKey(record) {
    this.set('key', { ...record, registeredAt: new Date().toISOString() });
  }

  getKey() {
    return this.get('key');
  }

  /** counter は単調増加。同じ assertion の再利用や巻き戻しを拒む。 */
  advanceCounter(counter) {
    const key = this.get('key');
    if (!key || counter <= key.counter) return false;
    this.set('key', { ...key, counter, lastUsedAt: new Date().toISOString() });
    return true;
  }

  countRequest(day, limit) {
    const usage = this.get('usage');
    const count = usage && usage.day === day ? usage.count : 0;
    if (count >= limit) return false;
    this.set('usage', { day, count: count + 1 });
    return true;
  }

  async alarm() {
    this.sql.exec('DELETE FROM kv WHERE k = ?', 'challenge');
  }
}
