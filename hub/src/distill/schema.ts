export const frameRecordsSchema = `
CREATE TABLE IF NOT EXISTS frame_records(record_id TEXT PRIMARY KEY, frame_id TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS frame_records_frame ON frame_records(frame_id);
`;
/** 用户说过"不属于这条线程"的片段。整理时不再把片段归回这些线程。不改 user_version：旧版 hub 忽略这张表，回滚不受影响。 */
export const frameRejectionsSchema = `
CREATE TABLE IF NOT EXISTS frame_rejections(frame_id TEXT NOT NULL, thread_id TEXT NOT NULL, at TEXT NOT NULL, PRIMARY KEY(frame_id, thread_id));
`;
export const distillSchema = `
CREATE TABLE frames(id TEXT PRIMARY KEY,t_start_ms INTEGER,t_end_ms INTEGER,key TEXT NOT NULL,record_ids TEXT NOT NULL,chars INTEGER,private INTEGER,status TEXT NOT NULL);
CREATE TABLE assignments(frame_id TEXT PRIMARY KEY,thread_id TEXT NOT NULL,method TEXT NOT NULL,confidence REAL);
CREATE TABLE threads(id TEXT PRIMARY KEY,project_id TEXT,status TEXT NOT NULL,title TEXT NOT NULL,brief TEXT,detail TEXT,first_ms INTEGER,last_ms INTEGER,active_minutes INTEGER,sessions INTEGER,needs_regen INTEGER NOT NULL DEFAULT 1,updated_at TEXT);
CREATE TABLE projects(id TEXT PRIMARY KEY,name TEXT NOT NULL,confirmed INTEGER NOT NULL DEFAULT 0,keys TEXT NOT NULL,brief TEXT,detail TEXT,salience REAL,last_ms INTEGER,needs_regen INTEGER NOT NULL DEFAULT 1,updated_at TEXT);
CREATE TABLE facts(id TEXT PRIMARY KEY,thread_id TEXT,project_id TEXT,kind TEXT NOT NULL,text TEXT NOT NULL,reason TEXT,evidence TEXT NOT NULL,confidence REAL,origin TEXT NOT NULL,valid_at TEXT NOT NULL,invalid_at TEXT,superseded_by TEXT,created_at TEXT NOT NULL);
CREATE TABLE days(date TEXT PRIMARY KEY,brief TEXT,detail TEXT,needs_regen INTEGER NOT NULL DEFAULT 1,updated_at TEXT);
CREATE TABLE pending(id TEXT PRIMARY KEY,kind TEXT NOT NULL,payload TEXT NOT NULL,created_at TEXT NOT NULL,resolved_at TEXT,resolution TEXT);
CREATE TABLE distill_state(k TEXT PRIMARY KEY,v TEXT);
CREATE TABLE llm_usage(id TEXT PRIMARY KEY,at TEXT,tier TEXT,provider TEXT,model TEXT,input_chars INTEGER,output_chars INTEGER,input_tokens INTEGER,output_tokens INTEGER,ms INTEGER,ok INTEGER,error TEXT);
CREATE INDEX frames_time ON frames(t_start_ms,id);
CREATE INDEX frames_status ON frames(status);
CREATE INDEX assignments_thread ON assignments(thread_id);
CREATE INDEX threads_project ON threads(project_id,status,last_ms DESC,id DESC);
CREATE INDEX threads_time ON threads(last_ms DESC,id DESC);
CREATE INDEX facts_thread ON facts(thread_id,invalid_at);
CREATE INDEX facts_project ON facts(project_id,invalid_at);
CREATE INDEX pending_open ON pending(resolved_at,created_at);
${frameRecordsSchema}
PRAGMA user_version=2;
`;

/** v9：任务名可空，旧用量保持 NULL；由 HubDB 在迁移事务内检查列后执行。 */
export const usageTaskSchema = `ALTER TABLE llm_usage ADD COLUMN task TEXT;`;
