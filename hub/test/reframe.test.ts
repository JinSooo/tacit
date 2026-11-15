import { expect, test } from 'bun:test';
import { fixture, setup } from './helpers.ts';
import { DistillStore, type Frame } from '../src/distill/store.ts';
import { repairFrameBoundaries } from '../src/distill/reframe.ts';
import { assignStep } from '../src/distill/run.ts';
import { persistFrames } from '../src/distill/frames.ts';
const at='2026-11-13T10:00:00+09:00',start=Date.parse(at);
function legacy(ctx:ReturnType<typeof setup>,store:DistillStore,id='mixed'){
 const records=['mobile','settings'].map((s,i)=>fixture({source:'codex.session',source_ref:id+'-'+s+'#1',t_start:new Date(start+i*60000).toISOString(),context:{repo:'/synthetic/repo'},body:'[我] 合成'+s}));ctx.db.ingest(records);
 const f:Frame={id,key:'repo:/synthetic/repo',record_ids:records.map(r=>r.id),t_start_ms:start,t_end_ms:start+60000,chars:20,private:0,status:'new'};store.createFrame(f);return {f,records};
}
function thread(store:DistillStore,id='old'){store.upsertThread({id,title:'旧混合标题',brief:'旧混合摘要',detail:{progress:'旧混合详情'},status:'done',needs_regen:0,project_id:'p',first_ms:start,last_ms:start+60000});}
test('旧混合片段重切：记录不删、拒绝归属保留，旧摘要及自动事实不能参与重新归属',()=>{
 const ctx=setup();try{
 const s=new DistillStore(ctx.db);s.upsertProject({id:'p',name:'合成',keys:{repos:[],hosts:[],chats:[]},brief:'旧项目',needs_regen:0});thread(s);thread(s,'rejected');const {f,records}=legacy(ctx,s);s.assign(f.id,'old','llm',.8);
 ctx.db.db.prepare('INSERT INTO frame_rejections VALUES(?,?,?)').run(f.id,'rejected',at);
 s.writeFact({id:'llm',kind:'next',text:'错误归属产生的下一步',evidence:[records[0]!.id],origin:'llm',thread_id:'old',valid_at:at,created_at:at});
 ctx.db.db.prepare('INSERT INTO pending(id,kind,payload,created_at,resolved_at,resolution) VALUES(?,?,?,?,?,?)').run('confirmed','thread_done',JSON.stringify({thread_id:'old'}),at,at,'done');
 s.setState('digest:old',{frames:[f.id],records:2});s.setState('now',{brief:'旧混合摘要'});s.upsertDay({date:'2026-11-13',brief:'旧日记',needs_regen:0});
 const before=records.map(r=>ctx.db.get(r.id));const r=repairFrameBoundaries(s,[f.id]);
 expect(r.replaced).toBe(1);expect(r.created).toBe(2);expect(s.frames()).toHaveLength(2);expect(s.frames().every(n=>n.id!==f.id&&n.status==='new')).toBe(true);
 expect(s.frames().flatMap(n=>n.record_ids).sort()).toEqual(records.map(r=>r.id).sort());expect(records.map(r=>ctx.db.get(r.id))).toEqual(before);
 for(const n of s.frames())expect(s.rejectedThreads(n.id)).toEqual(['rejected']);
 expect(ctx.db.db.prepare('SELECT count(*) n FROM assignments').get()).toEqual({n:0});expect(s.thread('old')?.status).toBe('done');expect(s.thread('old')?.brief).toBeNull();expect(s.thread('old')?.title).not.toContain('旧混合');
 expect(s.getState('digest:old')).toBeNull();expect(s.getState('now')).toBeNull();expect(ctx.db.db.prepare("SELECT resolution FROM pending WHERE id='confirmed'").get()).toEqual({resolution:'done'});expect(s.getState<number>('content_revision')).toBeGreaterThan(0);expect(s.facts('thread_id','old')).toHaveLength(0);expect(s.project('p')?.brief).toBeNull();expect(s.day('2026-11-13')?.brief).toBeNull();
 expect(repairFrameBoundaries(s,s.frames().map(f=>f.id)).replaced).toBe(0);expect(persistFrames(ctx.db,0,start+3600000).frames).toHaveLength(0);
 }finally{ctx.cleanup();}
});
test('用户手动归属和有效用户事实不被自动重分组覆盖',()=>{
 const ctx=setup();try{const s=new DistillStore(ctx.db);thread(s);const a=legacy(ctx,s,'assigned'),b=legacy(ctx,s,'fact');s.assign(a.f.id,'old','user',1);s.assign(b.f.id,'old','llm',.9);
 s.writeFact({id:'user',kind:'decision',text:'用户决定',evidence:[b.records[0]!.id],origin:'user',thread_id:'old',valid_at:at,created_at:at});const before=s.frames();
 const result=repairFrameBoundaries(s,[a.f.id,b.f.id]);expect(result.replaced).toBe(0);expect(result.protected.sort()).toEqual(['assigned','fact']);expect(s.frames()).toEqual(before);expect(s.facts('thread_id','old')[0]?.text).toBe('用户决定');
 }finally{ctx.cleanup();}
});
test('候选中的旧片段被替换后，不留下悬挂ID或复用污染候选标题',()=>{
 const ctx=setup();try{const s=new DistillStore(ctx.db);const {f}=legacy(ctx,s);ctx.db.db.prepare("UPDATE frames SET status='candidate' WHERE id=?").run(f.id);s.setState('candidates',[{id:'c',title:'污染候选',frame_ids:[f.id],minutes:1,last_ms:start,project_id:null}]);
 repairFrameBoundaries(s,[f.id]);expect(s.getState('candidates')).toEqual([]);expect(ctx.db.db.prepare('SELECT count(*) n FROM frame_records fr LEFT JOIN frames f ON f.id=fr.frame_id WHERE f.id IS NULL').get()).toEqual({n:0});
 }finally{ctx.cleanup();}
});
test('写入失败时整个重切事务回滚，旧关系与revision保持',()=>{
 const ctx=setup();try{const s=new DistillStore(ctx.db);thread(s);const {f}=legacy(ctx,s);s.assign(f.id,'old','llm',1);const before=s.frames();
 ctx.db.db.exec("CREATE TRIGGER reject_reframe BEFORE INSERT ON frames BEGIN SELECT RAISE(ABORT,'synthetic rollback'); END");expect(()=>repairFrameBoundaries(s,[f.id])).toThrow('synthetic rollback');expect(s.frames()).toEqual(before);expect(s.thread('old')?.brief).toBe('旧混合摘要');expect(s.getState('content_revision')).toBeNull();
 }finally{ctx.cleanup();}
});

test('重切时在途归属响应被revision拒绝，不产生旧片段的幽灵归属',async()=>{
 const ctx=setup();try{const s=new DistillStore(ctx.db);thread(s);const {f}=legacy(ctx,s);
 const llm={async complete<T>(){repairFrameBoundaries(s,[f.id]);return {ok:true as const,data:{items:[{frame_id:'s1',thread_id:'t1',new_thread_title:null,ignore:false,confidence:1}]} as T,ms:1};}};
 const result=await assignStep({db:ctx.db,llm},s,start+3600000);expect(result.failed).toBeGreaterThan(0);expect(ctx.db.db.prepare('SELECT count(*) n FROM assignments').get()).toEqual({n:0});expect(s.frames().some(n=>n.id===f.id)).toBe(false);
 }finally{ctx.cleanup();}
});
