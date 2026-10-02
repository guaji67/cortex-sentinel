const {test}=require('node:test');
const assert=require('node:assert/strict');
const {build}=require('../../Resources/Workbench/panorama.js');
const domain={id:'P1',label:'域:对话',name:'对话',band:'产品'};
const ticket=(key,status,labels,extra={})=>({key,status,labels,title:key,...extra});
test('无标签旧分流单独归入未归类，分组总数守恒',()=>{
  const p=build({domains:[domain],tickets:[ticket('COR-1','todo',[],{domain:'P1'}),ticket('COR-2','blocked',[domain.label]),ticket('COR-3','done',[domain.label])]});
  assert.equal(p.cards.find(c=>c.id==='__unclassified__').rows[0].key,'COR-1');
  assert.equal(p.cards.reduce((n,c)=>n+c.rows.length,0),p.live.length);
  assert.equal(p.cards.find(c=>c.id==='P1').blockedShare,'100.0%');
});
test('新域标签自动长出格，多个主域保留在未归类',()=>{
  const p=build({domains:[domain],tickets:[ticket('COR-1','todo',['域:新板块']),ticket('COR-2','todo',['域:新板块',domain.label])]});
  assert.equal(p.cards.find(c=>c.name==='新板块').rows.length,1);
  assert.equal(p.cards.find(c=>c.id==='__unclassified__').rows.length,1);
});
test('新登记家族按标签自动进板块，撤下后消失',()=>{
  const track={kind:'track',id:'new',title:'新窗口',owner:'负责人',ticket_labels:['家族:测试']};
  const snapshot={domains:[domain],tickets:[ticket('COR-1','in_progress',[domain.label,'家族:测试'])],entities:[track]};
  let p=build(snapshot);assert.equal(p.trackCards[0].runningShare,'100.0%');assert.deepEqual(p.trackCards[0].owners,['负责人']);
  snapshot.entities[0].archived=true;assert.equal(build(snapshot).trackCards.length,0);
});
test('进行中与待评审分开，未知负责人不按执行者臆填',()=>{
  const p=build({domains:[domain],tickets:[ticket('COR-1','in_review',[domain.label],{assignee:'某执行者'}),ticket('COR-2','in_progress',[domain.label])]});
  assert.equal(p.cards[0].runningShare,'50.0%');assert.deepEqual(p.cards[0].owners,[]);
});
test('关票不成为合入证据，只使用显式主线记录',()=>{
  const snapshot={domains:[domain],tickets:[ticket('COR-1','done',[domain.label])]};
  assert.equal(build(snapshot).cards[0].merged.length,0);
  snapshot.merges={records:[{title:'已合',ticket_keys:['COR-1'],merge_sha:'synthetic-sha',url:'https://github.com/example/repo/pull/1'}]};
  assert.equal(build(snapshot).cards[0].merged.length,1);
});
test('域标签被摘后马上进未归类，不使用 domain 字段残值',()=>{
  const t=ticket('COR-1','todo',[domain.label],{domain:'P1'});const snapshot={domains:[domain],tickets:[t]};
  assert.equal(build(snapshot).cards[0].rows.length,1);t.labels=[];assert.equal(build(snapshot).cards[0].rows.length,0);
});
test('空快照保留未归类且不显示 NaN 百分比',()=>{
  const p=build({});assert.equal(p.cards.length,1);assert.equal(p.cards[0].runningShare,'0.0%');
});
