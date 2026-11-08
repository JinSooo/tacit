// 实验 0-D：SQLCipher + FTS5 + 中文检索能否在 Bun / Node 上一起用
// 运行：bun test.mjs  或  node test.mjs
import Database from "better-sqlite3-multiple-ciphers";
import { Jieba } from "@node-rs/jieba";
import { dict } from "@node-rs/jieba/dict.js";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const runtime = typeof Bun !== "undefined" ? `bun ${Bun.version}` : `node ${process.version}`;
const file = path.join(os.tmpdir(), `ra-exp-${process.pid}.db`);
const KEY = "test-key-不要用于生产";
const results = [];
const check = (name, ok, detail = "") => results.push({ name, ok: !!ok, detail });

const docs = [
  "下午和张三讨论华刚大屏的 mock 数据，决定换节点",
  "在 Cursor 里修改 ruilin-mock 的 mock.ts，提交了 3 个文件",
  "微信项目群：明天上午十点开会，记得带上设计稿",
  "浏览 Graphiti 文档，了解双时态知识图谱",
];
// 两字词、三字以上、英文、混合
const queries = ["节点", "大屏", "开会", "设计稿", "双时态", "mock", "ruilin", "张三", "华刚大屏", "大屏的mock", "十点开会"];

try {
  // 1. 加密打开、写入
  let db = new Database(file);
  db.pragma(`cipher='sqlcipher'`);
  db.pragma(`legacy=4`);
  db.pragma(`key='${KEY}'`);
  db.exec(`CREATE TABLE rec(id INTEGER PRIMARY KEY, body TEXT)`);

  const jieba = Jieba.withDict(dict);
  const seg = (s) => jieba.cutForSearch(s, true).filter((t) => t.trim()).join(" ");

  // 方案 A：FTS5 trigram
  db.exec(`CREATE VIRTUAL TABLE fts_tri USING fts5(body, tokenize='trigram')`);
  // 方案 C：中文按重叠两字片段（bigram）切，非中文原样保留，不依赖词典
  db.exec(`CREATE VIRTUAL TABLE fts_bi USING fts5(body_bi, tokenize='unicode61')`);
  // 方案 B：应用层 jieba 分词后存进 unicode61 列
  db.exec(`CREATE VIRTUAL TABLE fts_seg USING fts5(body_seg, tokenize='unicode61')`);

  const CJK = /[\u3400-\u9fff\uf900-\ufaff]+/g;
  const bigram = (s) => s.replace(CJK, (run) => {
    if (run.length === 1) return ` ${run} `;
    const out = [];
    for (let i = 0; i < run.length - 1; i++) out.push(run.slice(i, i + 2));
    return ` ${out.join(" ")} `;
  });
  const insBi = db.prepare(`INSERT INTO fts_bi(rowid, body_bi) VALUES (?, ?)`);
  const ins = db.prepare(`INSERT INTO rec(body) VALUES (?)`);
  const insTri = db.prepare(`INSERT INTO fts_tri(rowid, body) VALUES (?, ?)`);
  const insSeg = db.prepare(`INSERT INTO fts_seg(rowid, body_seg) VALUES (?, ?)`);
  db.transaction(() => {
    for (const d of docs) {
      const { lastInsertRowid: id } = ins.run(d);
      insTri.run(id, d);
      insSeg.run(id, seg(d));
      insBi.run(id, bigram(d));
    }
  })();
  check("SQLCipher 加密写入", true, runtime);

  // 2. 两种检索
  const qTri = db.prepare(`SELECT rowid FROM fts_tri WHERE fts_tri MATCH ?`);
  const qSeg = db.prepare(`SELECT rowid FROM fts_seg WHERE fts_seg MATCH ?`);
  const qBi = db.prepare(`SELECT rowid FROM fts_bi WHERE fts_bi MATCH ?`);
  const qLike = db.prepare(`SELECT id FROM rec WHERE replace(body, ' ', '') LIKE ?`);
  const table = [];
  for (const q of queries) {
    const expected = qLike.all(`%${q.replace(/\s/g, "")}%`).length;
    let tri;
    try { tri = qTri.all(`"${q}"`).length; } catch (e) { tri = `错误:${e.message}`; }
    const segQ = jieba.cut(q, true).filter((t) => t.trim()).map((t) => `"${t}"`).join(" ");
    const s = qSeg.all(segQ).length;
    const bi = qBi.all(`"${bigram(q).trim().split(/\s+/).join(" ")}"`).length;
    table.push({ query: q, 应命中: expected, trigram: tri, jieba: s, bigram: bi });
  }
  console.table(table);
  check("trigram 全部命中", table.every((r) => r.trigram === r.应命中));
  check("jieba 全部命中", table.every((r) => r.jieba === r.应命中));
  check("bigram 全部命中", table.every((r) => r.bigram === r.应命中));
  db.close();

  // 3. 文件确实加密了
  const head = fs.readFileSync(file).subarray(0, 16).toString("latin1");
  check("文件头不是明文 SQLite", !head.startsWith("SQLite format 3"), JSON.stringify(head.slice(0, 8)));

  // 4. 错误密钥打不开
  db = new Database(file);
  db.pragma(`cipher='sqlcipher'`);
  db.pragma(`legacy=4`);
  db.pragma(`key='wrong'`);
  let wrongFails = false;
  try { db.prepare(`SELECT count(*) FROM rec`).get(); } catch { wrongFails = true; }
  db.close();
  check("错误密钥打不开", wrongFails);

  // 5. 正确密钥重开，数据还在
  db = new Database(file);
  db.pragma(`cipher='sqlcipher'`);
  db.pragma(`legacy=4`);
  db.pragma(`key='${KEY}'`);
  const n = db.prepare(`SELECT count(*) c FROM rec`).get().c;
  db.close();
  check("正确密钥重开", n === docs.length, `${n} 条`);
} catch (e) {
  check("运行", false, e.stack);
} finally {
  for (const f of [file, file + "-wal", file + "-shm"]) fs.rmSync(f, { force: true });
}

for (const r of results) console.log(`${r.ok ? "PASS" : "FAIL"}  ${r.name}${r.detail ? "  · " + r.detail : ""}`);
process.exit(results.every((r) => r.ok) ? 0 : 1);
