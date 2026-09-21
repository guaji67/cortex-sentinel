'use strict';
const $ = s => document.querySelector(s);
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const activeStates = new Set(['backlog','todo','in_progress','in_review','blocked']);
const statusNames = {backlog:'待规划',todo:'待办',in_progress:'进行中',in_review:'待评审',blocked:'阻塞',done:'已关闭',cancelled:'不再处理',recorded:'已登记',repairing:'修复中',merged:'已合主干',delivered:'已送达',verified:'用户已验',dismissed:'排除 / 归并',source_closed:'来源已收口'};
const stateColors = {backlog:'#bdc7cc',todo:'#7295b9',in_progress:'#348c85',in_review:'#9676ac',blocked:'#c96c56',done:'#6b9575',cancelled:'#d0d1cd'};
let data = null, info = null, currentModule = '', parent = '', search = '', page = 0, deliveryMode = 'tickets', phase = '', refreshing = false, lastSuccess = 0;
let selectedEntity = null;
const entities = () => Array.isArray(data?.entities) ? data.entities : [];
const tracks = () => entities().filter(e => e.kind === 'track' && !e.archived).sort((a,b) => (a.order??999)-(b.order??999) || String(a.title).localeCompare(String(b.title),'zh'));
const problems = () => entities().filter(e => e.kind === 'problem');
const tickets = () => (data?.tickets || []).map(t => ({...t,...(data?.drafts?.tickets?.[t.key] || {})}));
const get = id => entities().find(e => e.id === id);
const time = iso => { const d = new Date(iso); return Number.isFinite(d.getTime()) ? d.toLocaleString('zh-CN',{month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false}) : '尚未取得'; };
const age = iso => {const n = Date.now() - new Date(iso).getTime(); return Number.isFinite(n) ? Math.max(0,n/1000) : Infinity;};
const tone = c => ['blue','teal','orange','green','gray','violet'].includes(c) ? c : 'gray';
function notice(text) { $('#notice').textContent=text; $('#notice').hidden=!text; }
async function api(path, options={}) {
  const response = await fetch(path,{...options,headers:{'Content-Type':'application/json',...(options.method ? {'X-Sentinel-Local':'1'} : {}),...options.headers}});
  const body = await response.json();
  if (!response.ok) { const error = new Error(body.error || `请求失败 (${response.status})`); error.status=response.status; throw error; }
  return body;
}
function route() {const raw=location.hash.slice(1); return raw.startsWith('track:') ? 'modules' : (['overview','modules','delivery','connect'].includes(raw) ? raw : 'overview');}
function goModule(id) {currentModule=id; parent='';search='';location.hash='track:'+encodeURIComponent(id);render();}
function head(title,kicker,subtitle='',right='') {return `<div class="page-head"><div><span class="eyebrow">${esc(kicker)}</span><h1>${esc(title)}</h1><div class="subtle">${subtitle}</div></div><div class="toolbar">${right}</div></div>`;}
function section(title,body,right='') {return `<section><div class="section-head"><h2>${esc(title)}</h2><span class="subtle">${right}</span></div>${body}</section>`;}
function metric(value,label,caption='',kind='') {return `<div class="metric ${kind}"><b>${esc(value)}</b><span>${esc(label)}</span><span class="caption">${esc(caption)}</span></div>`;}
function bar(rows) {const counts=Object.keys(stateColors).map(state=>[state,rows.filter(t=>t.status===state).length]); const total=rows.length||1;return `<div class="mini-bar" aria-label="${esc(counts.filter(([,n])=>n).map(([s,n])=>`${statusNames[s]} ${n}`).join('，'))}">${counts.map(([s,n])=>`<i style="width:${n/total*100}%;background:${stateColors[s]}"></i>`).join('')}</div>`;}
function mapRow(name,blocks) {return `<div class="map-row"><div class="group-label">${esc(name)}</div><div class="blocks" style="--columns:${Math.max(1,Math.min(6,blocks.length))}">${blocks.join('')}</div></div>`;}
function legend(items) {return `<div class="legend">${items.map(([color,label])=>`<span><i class="dot" data-tone="${tone(color)}"></i>${esc(label)}</span>`).join('')}</div>`;}
function domainMap() {
  const live=tickets().filter(t=>activeStates.has(t.status)), grouped=new Map();
  for(const domain of data?.domains||[]) {const band=domain.band||'责任域';if(!grouped.has(band))grouped.set(band,[]);grouped.get(band).push(domain);}
  if(!grouped.size)return '<p class="empty">还没有登记产品责任域。AI 可先登记板块；不用先把所有模块规划齐。</p>';
  return `<div class="legend">${Object.entries(stateColors).filter(([s])=>activeStates.has(s)).map(([s,c])=>`<span><i class="dot" style="background:${c}"></i>${statusNames[s]}</span>`).join('')}<span>票数是待处理清单，不是缺陷总数</span></div><div class="map">${[...grouped].map(([name,domains])=>mapRow(name,domains.map(d=>{
    const rows=live.filter(t=>t.domain===d.id), linked=tracks().filter(t=>(t.domains||[]).includes(d.id));
    return `<button class="block" data-domain="${esc(d.id)}" style="--tone:${/^#[a-fA-F0-9]{6}$/.test(d.color)?d.color:'#7b969f'}"><h3><span class="id">${esc(d.id)}</span>${esc(d.name)}</h3><div class="meta"><span>${rows.length} 张待处理</span><span>${linked.length?`${linked.length} 份板块图`:'尚未开图'}</span></div>${bar(rows)}</button>`;
  }))).join('')}</div>`;
}
function fleet() {
  const native=data?.sentinel||{}, machines=native.machines||[];
  if(!machines.length)return '<div class="muted-box">哨兵尚未取得机器读数；不以工单“进行中”冒充有人在执行。</div>';
  return `<div class="fleet">${machines.map(m=>{
    const stale=age(m.ts)>300, num=v=>typeof v==='number'&&Number.isFinite(v)?Math.round(v):null;
    const cpu=num(m.cpu_pct),mem=num(m.mem_used_pct);
    return `<div class="machine ${stale?'stale':''}"><header><b>${esc(m.id)}</b><span class="subtle">${stale?'旧读数':'最近读数'} · ${time(m.ts)}</span></header><div class="meta">${esc((m.executors||[]).slice(0,3).join(' · ') || '未提供当前执行者')} ${(m.executors||[]).length>3?`等 ${m.executors.length} 位`:''}</div><div class="meter">CPU ${cpu===null?'未知':cpu+'%'} ${cpu===null?'':`<progress value="${cpu}" max="100"></progress>`} 内存 ${mem===null?'未知':mem+'%'}</div></div>`;
  }).join('')}</div><p class="health-hint">读数直接来自哨兵。机器负载不代表交付成果；旧读数不代表机器仍在线。</p>${(native.lines||[]).filter(l=>l.active).length?`<details><summary class="subtle">${esc(native.host||'本机')} 的当前执行线 · ${(native.lines||[]).filter(l=>l.active).length}</summary><div class="compact-list">${(native.lines||[]).filter(l=>l.active).slice(0,40).map(l=>`<div class="status-line">${esc(l.id)} · ${esc(l.state)} · ${esc(l.model)} · ${time(l.updated_at)}</div>`).join('')}</div></details>`:''}`;
}
function overview() {
  const live=tickets().filter(t=>activeStates.has(t.status));
  const bugs=problems().filter(p=>p.classification==='confirmed_bug'&&!['verified','dismissed','source_closed'].includes(p.state));
  const verified=problems().filter(p=>p.state==='verified');
  $('#main').innerHTML=head('Cortex 开发全景','结构 · 问题 · 用户结果',`工单快照 ${time(data.synced_at)} · ${tracks().length} 个已开工板块`, '<button id="sync">刷新来源</button>')+
    `<div class="metrics">${metric(live.length,'待处理工单','修复、研究、需求均在内')}${metric(live.filter(t=>t.status==='blocked').length,'阻塞','先看卡在哪里','attention')}${metric(bugs.length||'—','登记缺陷未验',bugs.length?'只统计已确认的缺陷':'尚未核齐，不代表没有 bug','attention')}${metric(verified.length,'有用户验收记录','不是关票数','good')}</div>`+
    section('产品版图',domainMap(),`${(data.domains||[]).length} 个责任域`) +
    section('已开工的板块', `<div class="module-rack">${tracks().map(t=>`<button data-track="${esc(t.id)}"><b>${esc(t.title)}</b><span>${entities().filter(e=>e.track===t.id&&e.kind==='area'&&!e.archived).length} 块 · ${time(data.sources?.[t.id]?.observed_at||t.updated_at)}</span><span>↗</span></button>`).join('')||'<p class="empty">还没有登记。探索可以从一段自由正文开始。</p>'}</div>`) +
    section('正在执行的环境',fleet(), '辅助信息，不作绩效') +
    `<details><summary class="subtle">问题家族与验收链路</summary><div class="split">${collection('问题家族',data.families)}${collection('验收链路',data.journeys)}</div></details>`;
  $('#sync').onclick=async()=>{try{await api('/api/refresh',{method:'POST',body:'{}'});notice('正在同步。完整快照回来前保留原来的数。');}catch(e){notice(e.message);}};
}
function collection(title,rows) {return section(title,`<div class="compact-list">${(rows||[]).map((r,i)=>`<button data-collection="${title==='问题家族'?'families':'journeys'}:${i}">${esc(r.name||r.title||r.id||'查看')}<span>↗</span></button>`).join('')||'<span class="subtle">尚未登记</span>'}</div>`);}
function modulePage() {
  if(location.hash.startsWith('#track:')){const id=decodeURIComponent(location.hash.slice(7));if(currentModule!==id){currentModule=id;parent='';}}
  const list=tracks(); if(!get(currentModule))currentModule=list[0]?.id||'';
  const track=get(currentModule), source=data.sources?.[currentModule]||{};
  const picker=`<label class="subtle">板块 <select id="module-picker">${list.map(t=>`<option value="${esc(t.id)}" ${t.id===currentModule?'selected':''}>${esc(t.title)}</option>`).join('')}</select></label><input id="map-search" type="search" placeholder="找子块、票号或内容" aria-label="搜索板块内容" value="${esc(search)}">`;
  if(!track){$('#main').innerHTML=head('板块图','按实际问题生长','还没有开工资料',picker)+'<div class="empty">AI 先登记一个入口即可；内部可以边讨论边拆解，不必填满模板。接入方式在“连接与接入”。</div>';return;}
  const all=entities().filter(e=>e.track===currentModule&&e.kind==='area'&&!e.archived);
  let visible=all.filter(e=>search ? JSON.stringify(e).toLowerCase().includes(search.toLowerCase()) : (e.parent||'')===parent);
  const groupOrder=(source.groups||[]).map(g=>g.name), groups=new Map();
  visible.sort((a,b)=>{const ga=groupOrder.indexOf(a.group),gb=groupOrder.indexOf(b.group);return (ga<0?999:ga)-(gb<0?999:gb) || (a.order??999)-(b.order??999);});
  for(const block of visible){const group=block.group||'未分组';if(!groups.has(group))groups.set(group,[]);groups.get(group).push(block);}
  const map=[...groups].map(([name,blocks])=>mapRow(name,blocks.map(b=>{
    const children=all.filter(e=>e.parent===b.id).length;
    const open=problems().filter(p=>p.block_id===b.id&&p.classification==='confirmed_bug'&&!['verified','dismissed'].includes(p.state)).length;
    return `<button class="block" data-entity="${esc(b.id)}" data-tone="${tone(b.color||b.source_color)}"><h3>${esc(b.title)}</h3><div class="status-tag">${esc(b.status_label||b.source_label||'未记录判断')}</div>${b.short_note?`<div class="source-note">${esc(b.short_note)}</div>`:''}${children||open?`<div class="meta">${children?`${children} 个子块`:''}${open?`<span>${open} 个确认缺陷待验</span>`:''}</div>`:''}</button>`;
  }))).join('');
  const relations=entities().filter(e=>e.kind==='relation'&&(e.track===currentModule||get(e.to)?.track===currentModule));
  const freeNotes=entities().filter(e=>e.track===currentModule&&e.kind==='note'&&!e.archived);
  $('#main').innerHTML=head(track.title,'板块图 / '+all.length+' 块',`<span class="source-stamp">${source.name?'原图更新 '+time(source.observed_at):'维护更新 '+time(track.updated_at)} · 颜色沿用维护者判断，用户验收另记</span>`,picker)+
    (data.source_errors?.[currentModule]?`<p class="warning">${esc(data.source_errors[currentModule])}</p>`:'')+
    (parent?`<div class="breadcrumb"><button id="root-map">${esc(track.title)}</button> / ${esc(get(parent)?.title||parent)}</div>`:'')+
    legend(Object.entries(source.legend||track.legend||{}))+
    `<div class="map" aria-label="${esc(track.title)}结构图">${map||'<p class="empty">这一层还没有拆分，或没有匹配内容。可以直接阅读板块正文。</p>'}</div>`+
    `<div class="seams">${relations.map(r=>`<button data-entity="${esc(r.id)}">${esc(get(r.from)?.title||r.from)}<span class="arrow">↔</span>${esc(get(r.to)?.title||r.to)} <span class="subtle">${r.certainty==='confirmed'?'':'待确认'}</span></button>`).join('')}${(source.external||[]).map(x=>`<span class="unresolved">${esc(x)} · 接缝引用</span>`).join('')}</div>`+
    `<div class="section-head"><h2>深入这块</h2><button data-entity="${esc(track.id)}">板块正文与 AI 接手 ↗</button></div>`+
    `<div class="module-rack">${freeNotes.map(n=>`<button data-entity="${esc(n.id)}">${esc(n.title)}<span>笔记 ↗</span></button>`).join('')}<button id="module-problems">问题与交付 <span>${problems().filter(p=>p.track===currentModule).length} 条登记 ↗</span></button>${(source.sections||[]).length?'<button id="source-sections">研究、计划与依据 <span>完整原稿内容 ↗</span></button>':''}</div>`;
  $('#module-picker').onchange=e=>goModule(e.target.value);
  $('#map-search').oninput=e=>{const at=e.target.selectionStart;search=e.target.value;modulePage();bind();$('#map-search').focus();$('#map-search').setSelectionRange(at,at);};
  if($('#root-map'))$('#root-map').onclick=()=>{parent='';render();};
  $('#module-problems').onclick=()=>{deliveryMode='problems';phase='';search='';page=0;location.hash='delivery';};
  if($('#source-sections'))$('#source-sections').onclick=()=>show('研究、计划与依据','来源原稿 · '+time(source.observed_at), (source.sections||[]).map(s=>`<details><summary>${esc(s.title)}</summary><div class="body-copy">${esc(s.body)}</div></details>`).join(''));
}
function delivery() {
  const isTickets=deliveryMode==='tickets';
  let rows=isTickets?tickets():problems();
  if(!isTickets&&currentModule)rows=rows.filter(r=>r.track===currentModule);
  const states=isTickets?['backlog','todo','in_progress','in_review','blocked','done','cancelled']:['recorded','repairing','merged','delivered','verified','dismissed','source_closed'];
  const counts=Object.fromEntries(states.map(s=>[s,rows.filter(r=>(isTickets?r.status:r.state)===s).length]));
  if(phase) rows=rows.filter(r=>(isTickets?r.status:r.state)===phase);
  else if(isTickets)rows=rows.filter(r=>activeStates.has(r.status));
  if(search)rows=rows.filter(r=>JSON.stringify(r).toLowerCase().includes(search.toLowerCase()));
  const total=rows.length;page=Math.min(page,Math.max(0,Math.ceil(total/40)-1));
  $('#main').innerHTML=head('问题与交付','分清工作量与用户结果',isTickets?'工单状态来自 Multica；关闭工单不自动变成用户验收。':'来源提及、确认缺陷和改进分别保留；不把历史清单全算成 bug。',`<input id="delivery-search" type="search" placeholder="搜索票号、内容、责任域" value="${esc(search)}">`)+
    `<div class="toolbar"><button data-delivery="tickets" ${isTickets?'class="primary"':''}>工单清单</button><button data-delivery="problems" ${!isTickets?'class="primary"':''}>问题与验收记录</button>${!isTickets?`<select id="delivery-module"><option value="">全部板块</option>${tracks().map(t=>`<option value="${esc(t.id)}" ${t.id===currentModule?'selected':''}>${esc(t.title)}</option>`).join('')}</select>`:''}</div>`+
    `<div class="stage-strip"><button data-phase="" class="${!phase?'selected':''}">${isTickets?'全部待处理':'全部记录'}</button>${states.map(s=>`<button data-phase="${s}" class="${phase===s?'selected':''}">${statusNames[s]} <b>${counts[s]}</b></button>`).join('')}</div>`+
    `<table class="ticket-table"><thead><tr><th>身份</th><th>问题 / 工作</th><th>阶段</th><th>${isTickets?'主责域':'类型'}</th></tr></thead><tbody>${rows.slice(page*40,page*40+40).map(r=>`<tr><td>${esc(r.key||r.id)}</td><td><button ${isTickets?`data-ticket="${esc(r.key)}"`:`data-entity="${esc(r.id)}"`}>${esc(r.title)}</button></td><td>${esc(statusNames[r.status||r.state]||'未知')}</td><td>${esc(isTickets?((data.domains||[]).find(d=>d.id===r.domain)?.name||r.domain||'待分诊'):({source_only:'来源提及 · 未复核',confirmed_bug:'已确认缺陷',improvement:'改进'}[r.classification]||'未分类'))}</td></tr>`).join('')}</tbody></table>`+
    `<div class="pagination"><button id="prev" ${page===0?'disabled':''}>上一页</button><span class="subtle">${total} 条 · 第 ${page+1} / ${Math.max(1,Math.ceil(total/40))} 页</span><button id="next" ${(page+1)*40>=total?'disabled':''}>下一页</button></div>`;
  $('#prev').onclick=()=>{page--;render();};$('#next').onclick=()=>{page++;render();};
  $('#delivery-search').oninput=e=>{const at=e.target.selectionStart;search=e.target.value;page=0;delivery();bind();$('#delivery-search').focus();$('#delivery-search').setSelectionRange(at,at);};
  if($('#delivery-module'))$('#delivery-module').onchange=e=>{currentModule=e.target.value;page=0;render();};
}
async function connect() {
  const local=info?.local;
  $('#main').innerHTML=head('连接与接入','哨兵的一部分','随哨兵启动、退出和更新；不是另一套后台服务。')+`<div class="connection-grid"><section><h2>这台机器怎么用</h2><div id="connection-info" class="subtle">读取连接设置…</div></section><section><h2>AI 怎么维护</h2><p>先梳理实际问题，再登记板块入口。结构、自由正文、跨板块关系都可以逐步增加，不需要填完模板。</p><p>每次改动带修订号；验收带证据。工单仍由 Multica 管，工作台不负责派工。</p><button id="guide">打开维护协议</button><p>维护工具和 Skill 随哨兵安装包更新。本机位置登记在 <code>~/.config/cortex-board/location.json</code>；密钥不放在页面里。</p></section></div>`;
  $('#guide').onclick=async()=>{try{const result=await api('/api/guide');show('AI 维护协议','版本 1',`<div class="body-copy">${esc(result.guide)}</div>`);}catch(e){notice(e.message);}};
  if(local){const install=document.createElement('button');install.textContent='启用随哨兵更新的 AI 技能';install.onclick=async()=>{try{const result=await api('/api/install-skill',{method:'POST',body:'{}'});notice(result.message);}catch(e){notice(e.message);}};$('#guide').after(install);}
  if(!local){$('#connection-info').innerHTML='<p>这是共享工作台的浏览入口。电视或普通浏览器只需地址和浏览配对码；要维护某板块，由保存共享账的机器发放该板块权限。</p>';return;}
  try{
    const config=await api('/api/settings'); if(route()!=='connect')return;
    $('#connection-info').innerHTML=`<p>当前：<b>${{host:'本机保存共享账',joined:'连接已有共享账',unconfigured:'还没有选择'}[config.mode]||'未知'}</b></p>${config.mode==='host'?`<p>其他电脑安装同一份哨兵，打开开发工作台，选择连接下面的地址。电视只要用浏览器打开这个地址。</p><label class="field">局域网地址<input readonly value="${esc(config.address)}"></label><label class="field">浏览配对码（只读，不授予 AI 写入权）<input type="password" readonly id="view-code" value="${esc(config.view_key)}"></label><button id="reveal-code">显示配对码</button><p>数据保存在 ${esc(config.data_directory)}，升级 App 不覆盖。</p>`:`<label class="field">共享工作台地址<input id="hub-url" placeholder="http://某台机器.local:8935" value="${esc(config.hub_url)}" list="known-peers"></label><datalist id="known-peers">${(config.peers||[]).map(p=>`<option value="${esc(p)}"></option>`).join('')}</datalist><label class="field">浏览配对码<input id="hub-key" type="password" autocomplete="off"></label><button id="join-hub" class="primary">连接已有工作台</button>${config.mode==='unconfigured'?'<p>只有决定让这台机器保存共享账时，才选择下面这一项。</p><button id="host-hub">让本机保存共享账</button>':''}`}`;
    if($('#reveal-code'))$('#reveal-code').onclick=()=>{$('#view-code').type=$('#view-code').type==='password'?'text':'password';};
    if($('#join-hub'))$('#join-hub').onclick=async()=>{try{await api('/api/settings',{method:'POST',body:JSON.stringify({mode:'joined',hub_url:$('#hub-url').value,hub_key:$('#hub-key').value})});await refresh();}catch(e){notice(e.message);}};
    if($('#host-hub'))$('#host-hub').onclick=async()=>{try{await api('/api/settings',{method:'POST',body:JSON.stringify({mode:'host'})});await refresh();}catch(e){notice(e.message);}};
  }catch(e){notice(e.message);}
}
function show(title,kicker,html) {$('#detail-title').textContent=title;$('#detail-kicker').textContent=kicker;$('#detail-body').innerHTML=html;if(!$('#detail').open)$('#detail').showModal();$('#detail').scrollTop=0;bind($('#detail-body'));}
function detail(id) {
  const e=get(id);if(!e)return;selectedEntity=id;
  const related=problems().filter(p=>p.block_id===id); const children=entities().filter(x=>x.parent===id);
  const source=data.sources?.[e.track], sourceBlock=source?.blocks?.find(b=>b.id===id);
  const text=e.body||e.purpose||'', notes=e.notes||sourceBlock?.notes||[];
  const associations=entities().filter(r=>r.kind==='relation'&&(r.from===id||r.to===id));
  let html=`${text?`<div class="body-copy">${esc(typeof text==='string'?text:JSON.stringify(text,null,2))}</div>`:''}${notes.length?`<ul>${notes.map(n=>`<li>${esc(typeof n==='string'?n:JSON.stringify(n))}</li>`).join('')}</ul>`:''}`;
  for(const [key,label] of Object.entries({owner:'当前维护者',machine:'明确登记的执行环境',source_status_text:'维护者判断',source_plan:'推进安排',blocker:'卡点',next_action:'下一步',neighbors:'相关结构'})){if(e[key])html+=`<h3>${label}</h3><div class="body-copy">${esc(e[key])}</div>`;}
  if(children.length)html+=`<h3>内部结构</h3><div class="compact-list">${children.map(c=>`<button data-entity="${esc(c.id)}">${esc(c.title)} ↗</button>`).join('')}</div><button id="drill">在地图中展开这一层</button>`;
  if(e.kind==='track')html+=`<h3>板块边界</h3><p>${esc(e.boundary||'尚未单独记录边界；不代表没有跨模块影响。')}</p>`;
  if(e.evidence)html+=`<h3>验收证据</h3><pre>${esc(JSON.stringify(e.evidence,null,2))}</pre>`;
  if(related.length)html+=`<h3>相关问题 · ${related.length}</h3><div class="compact-list">${related.slice(0,25).map(p=>`<button data-entity="${esc(p.id)}">${esc(p.title)}<small>${esc(statusNames[p.state]||'待确认')}</small></button>`).join('')}</div>${related.length>25?'<p class="subtle">其余记录在“问题与交付”中查看。</p>':''}`;
  if(associations.length)html+=`<h3>影响与接缝</h3><div class="compact-list">${associations.map(r=>`<button data-entity="${esc(r.id)}">${esc(r.title)}</button>`).join('')}</div>`;
  if((e.ticket_ids||[]).length)html+=`<h3>关联工单</h3><div class="module-rack">${e.ticket_ids.map(k=>`<button data-ticket="${esc(k)}">${esc(k)}</button>`).join('')}</div>`;
  if((e.references||[]).length)html+=`<h3>依据</h3><div class="body-copy">${esc(e.references.join('\n'))}</div>`;
  html+=`<h3>交给 AI 继续</h3><button id="copy-handoff">复制接手文本</button><p class="subtle">包含身份、当前修订、正文与关联；不自动派工、不更改工单。</p><details><summary>完整维护内容（扩展字段也保留）</summary><pre>${esc(JSON.stringify(e,null,2))}</pre></details>`;
  show(e.title,`${get(e.track)?.title||e.track} / ${e.id} · 修订 ${e.revision||0}`,html);
  $('#copy-handoff').onclick=async()=>{const text=`请先读取 cortex-governance-board Skill，再接手 ${e.title}。\n工作台记录 ${e.id}，修订 ${e.revision||0}。先核对最新来源，不以关票或合 PR 代替用户验收。保留跨板块影响，不受显示提纲限制。\n\n${JSON.stringify(e,null,2)}`;try{await navigator.clipboard.writeText(text);$('#copy-handoff').textContent='已复制';}catch{show('AI 接手文本','可选中复制',`<textarea readonly>${esc(text)}</textarea>`);}};
  if($('#drill'))$('#drill').onclick=()=>{$('#detail').close();currentModule=e.track;parent=e.id;search='';if(route()!=='modules')location.hash='modules';render();};
}
function domainDetail(id) {
  const d=(data.domains||[]).find(d=>d.id===id);if(!d)return;
  const related=tracks().filter(t=>(t.domains||[]).includes(id)), rows=tickets().filter(t=>t.domain===id&&activeStates.has(t.status));
  const draft=data.drafts?.domains?.[id]||{};
  show(d.name,`${id} / ${d.band||'责任域'}`,`<p>${esc(d.purpose)}</p><h3>边界</h3><p>${esc(d.boundary||'尚未记录')}</p><h3>已开工板块</h3><div class="module-rack">${related.map(t=>`<button data-track="${esc(t.id)}">${esc(t.title)} ↗</button>`).join('')||'<span class="subtle">尚未开图，不凭空补齐。</span>'}</div><h3>当前安排</h3><label class="field">负责人<input id="draft-owner" value="${esc(draft.owner||'')}"></label><label class="field">这轮要交付什么<textarea id="draft-goal">${esc(draft.goal||'')}</textarea></label>${info?.local&&data.connection?.mode==='host'?'<button id="save-draft">保存管理草稿</button>':'<p class="subtle">当前连接为浏览权限。</p>'}<h3>待处理工单 · ${rows.length}</h3><div class="compact-list">${rows.slice(0,15).map(t=>`<button data-ticket="${esc(t.key)}">${esc(t.key+' '+t.title)}</button>`).join('')}</div><h3>仓库入口</h3><div class="body-copy">${esc((d.docs||[]).join('\n'))}</div>`);
  if($('#save-draft'))$('#save-draft').onclick=async()=>{try{const drafts=JSON.parse(JSON.stringify(data.drafts||{domains:{},tickets:{}}));drafts.domains[id]={owner:$('#draft-owner').value,goal:$('#draft-goal').value};await api('/api/drafts',{method:'PUT',body:JSON.stringify({base_revision:data.draft_revision,drafts})});$('#save-draft').textContent='已保存';await refresh(false);}catch(e){notice(e.message);}};
}
function ticketDetail(key) {
  const ticket=tickets().find(t=>t.key===key)||{key,title:key};
  const matched=problems().filter(p=>(p.ticket_ids||[]).includes(key));
  show(ticket.title,key,`<p>工单阶段：${esc(statusNames[ticket.status]||'当前快照未收录')}。这不等于用户验收。</p><div class="body-copy">${esc(ticket.note||'')}</div><h3>关联验收记录</h3><div class="compact-list">${matched.map(p=>`<button data-entity="${esc(p.id)}">${esc(p.title)}</button>`).join('')||'<span class="subtle">尚未关联用户验收记录</span>'}</div><details><summary>工单快照</summary><pre>${esc(JSON.stringify(ticket,null,2))}</pre></details><button id="load-ticket">读取 Multica 原票详情</button><div id="ticket-live"></div>`);
  $('#load-ticket').onclick=async()=>{const button=$('#load-ticket');button.disabled=true;button.textContent='读取中…';try{const body=await api('/api/tickets/'+encodeURIComponent(key));if($('#ticket-live'))$('#ticket-live').innerHTML=`<pre>${esc(JSON.stringify(body.issue,null,2))}</pre>`;}catch(e){if($('#ticket-live'))$('#ticket-live').textContent=e.message;}finally{button.disabled=false;button.textContent='读取 Multica 原票详情';}};
}
function bind(root=document) {
  root.querySelectorAll('[data-track]').forEach(b=>b.onclick=()=>{if($('#detail').open)$('#detail').close();goModule(b.dataset.track);});
  root.querySelectorAll('[data-entity]').forEach(b=>b.onclick=()=>detail(b.dataset.entity));
  root.querySelectorAll('[data-domain]').forEach(b=>b.onclick=()=>domainDetail(b.dataset.domain));
  root.querySelectorAll('[data-ticket]').forEach(b=>b.onclick=()=>ticketDetail(b.dataset.ticket));
  root.querySelectorAll('[data-delivery]').forEach(b=>b.onclick=()=>{deliveryMode=b.dataset.delivery;phase='';page=0;search='';render();});
  root.querySelectorAll('[data-phase]').forEach(b=>b.onclick=()=>{phase=b.dataset.phase;page=0;render();});
  root.querySelectorAll('[data-collection]').forEach(b=>b.onclick=()=>{const [kind,index]=b.dataset.collection.split(':');const row=data[kind][Number(index)];show(row.title||row.name||row.id,'依据来自原工作台',`<pre>${esc(JSON.stringify(row,null,2))}</pre>`);});
}
function render() {
  if(!data)return;
  const view=route();document.querySelectorAll('.mast nav a').forEach(a=>a.classList.toggle('active',a.hash==='#'+view));
  if(data.connection?.mode==='unconfigured'&&view!=='connect'){location.hash='connect';return;}
  if(view==='overview')overview();else if(view==='modules')modulePage();else if(view==='delivery')delivery();else connect();
  bind();
  $('#footer').textContent=`哨兵工作台 · ${data.connection?.mode==='joined'?'连接共享账':'本机保存共享账'} · 工单同步 ${time(data.synced_at)} · 页面读取 ${time(lastSuccess)} · 未知 ≠ 没有问题`;
}
async function refresh(repaint=true) {
  if(refreshing)return;refreshing=true;
  try{
    if(!info)info=await api('/api/info');
    data=await api('/api/overview');lastSuccess=Date.now();
    const warnings=[];
    if(data.sync?.error)warnings.push(data.sync.error);
    if(data.sync?.syncing)warnings.push('Multica 正在同步；显示上次完整快照');
    if(data.synced_at&&age(data.synced_at)>3600)warnings.push('工单快照超过一小时，不能据此判断此刻执行情况');
    notice(warnings.join(' · '));
    // Never replace an open draft or active text input on a timer.
    if(repaint&&!$('#detail').open&&!['INPUT','TEXTAREA','SELECT'].includes(document.activeElement?.tagName))render();
  }catch(e){
    notice((data?'连接中断，保留上次画面。':'')+e.message);
    if(!data&&e.status===401){$('#main').innerHTML=head('连接共享工作台','需要浏览配对码','在保存共享账的哨兵中，“连接与接入”可查看。')+'<label class="field">浏览配对码<input id="pair-key" type="password" autocomplete="off"></label><button id="pair" class="primary">连接</button>';$('#pair').onclick=async()=>{try{await api('/api/pair',{method:'POST',body:JSON.stringify({key:$('#pair-key').value})});await refresh();}catch(err){notice(err.message);}};}
  }finally{refreshing=false;}
}
$('#close-detail').onclick=()=>{$('#detail').close();selectedEntity=null;};
$('#wall').onclick=()=>{document.body.classList.toggle('wall');$('#wall').textContent=document.body.classList.contains('wall')?'退出大屏':'大屏';};
window.addEventListener('hashchange',()=>{search='';page=0;render();});
refresh();setInterval(()=>refresh(),30000);
