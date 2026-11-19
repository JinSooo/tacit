import { Database } from "bun:sqlite";
import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

export interface Message { time: number; role: "user" | "assistant"; text: string }
type Row = Omit<Message, "text"> & { text: Uint8Array };
const NONCE_BYTES = 12;
const TAG_BYTES = 16;
const HEADER_BYTES = NONCE_BYTES + TAG_BYTES;

/** 把同一小时跨文件、乱序到达的消息排好序，再按原规则分条。
 * 临时文件只保存加密正文，密钥只在本次进程内。分条时逐行解密。
 */
export function messageBuffer() {
  const db = new Database(":memory:");
  try {
    // TEMP 表的溢出页由 SQLite 写入自动清理的临时文件。
    db.exec(`
      PRAGMA temp_store = FILE;
      PRAGMA temp.cache_size = -2048;
      PRAGMA temp.journal_mode = OFF;
      CREATE TEMP TABLE messages (
        bucket INTEGER NOT NULL, time INTEGER NOT NULL, role TEXT NOT NULL,
        text BLOB NOT NULL, hash TEXT, UNIQUE(bucket, hash)
      );
      CREATE INDEX messages_in_order ON messages(bucket, time);
      BEGIN;
    `);
    const key = randomBytes(32);
    const insert = db.query("INSERT INTO messages VALUES (?, ?, ?, ?, ?) ON CONFLICT(bucket, hash) DO NOTHING");
    const ordered = db.query<Row, [number]>("SELECT time, role, text FROM messages WHERE bucket = ? ORDER BY time, rowid");
    const hashes = db.query<{ hash: string }, [number]>("SELECT hash FROM messages WHERE bucket = ? AND hash IS NOT NULL");
    const size = db.query<{ count: number; bytes: number }, [number]>(`SELECT count(*) AS count, COALESCE(sum(length(text) - ${HEADER_BYTES}), 0) AS bytes FROM messages WHERE bucket = ?`);
    return {
      close: () => db.close(),
      add(bucket: number, message: Message, hash: string | null) {
        const nonce = randomBytes(NONCE_BYTES);
        const cipher = createCipheriv("aes-256-gcm", key, nonce);
        const ciphertext = cipher.update(message.text, "utf16le");
        cipher.final();
        insert.run(bucket, message.time, message.role, Buffer.concat([nonce, cipher.getAuthTag(), ciphertext]), hash);
      },
      *messages(bucket: number): Generator<Message> {
        for (const row of ordered.iterate(bucket)) {
          const decipher = createDecipheriv("aes-256-gcm", key, row.text.subarray(0, NONCE_BYTES));
          decipher.setAuthTag(row.text.subarray(NONCE_BYTES, HEADER_BYTES));
          const text = decipher.update(row.text.subarray(HEADER_BYTES));
          decipher.final();
          yield { time: row.time, role: row.role, text: text.toString("utf16le") };
        }
      },
      hashes: (bucket: number) => hashes.iterate(bucket),
      size: (bucket: number) => size.get(bucket)!,
    };
  } catch (error) {
    db.close();
    throw error;
  }
}
