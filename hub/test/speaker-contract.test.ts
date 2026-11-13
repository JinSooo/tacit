import {expect,test} from "bun:test";
import cases from "../../schema/fixtures/speaker-consolidation.json";
import {AudioStore} from "../src/audio.ts";
import {setup} from "./helpers.ts";
for (const sample of cases) test(`共享声纹合并契约：${sample.name}`,()=>{
  const ctx=setup(),store=new AudioStore(ctx.db),at="2026-11-13T00:00:00Z";
  try {
    for (const s of sample.speakers) {
      const v=Buffer.from(new Float32Array([...s.centroid,...Array(510).fill(0)]).buffer);
      ctx.db.db.prepare("INSERT INTO speakers(id,label,status,centroid,conversations,seconds,created_at) VALUES(?,?,'new',?,1,?,?)").run(s.local,s.local,v,s.seconds,at);
      ctx.db.db.prepare("INSERT INTO voice_embeddings VALUES(?,?,'mac',?,'mic',?,?,?,?)").run("fixture",s.local,s.local,s.seconds,v,at,at);
    }
    store.consolidateConversation("fixture");
    const rows=ctx.db.db.prepare("SELECT local,speaker_id FROM voice_embeddings").all() as {local:string;speaker_id:string}[];
    const grouped=new Map<string,string[]>();
    for(const row of rows) grouped.set(row.speaker_id,[...(grouped.get(row.speaker_id)??[]),row.local]);
    const groups=[...grouped.values()].map(g=>g.sort()).sort((a,b)=>a[0]!.localeCompare(b[0]!));
    expect(groups).toEqual(sample.groups);
  } finally {ctx.cleanup();}
});
