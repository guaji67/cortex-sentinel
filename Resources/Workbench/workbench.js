'use strict';
const $ = s => document.querySelector(s);
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const activeStates = new Set(['backlog','todo','in_progress','in_review','blocked']);
const statusNames = {backlog:'待规划',todo:'待办',in_progress:'进行中',in_review:'待评审',blocked:'阻塞',done:'已关闭',cancelled:'不再处理',recorded:'已登记',repairing:'修复中',merged:'已合主干',delivered:'已送达',verified:'用户已验',dismissed:'排除 / 归并',source_closed:'来源已收口'};
let data = null, info = null, currentModule = '', parent = '', search = '', page = 0, deliveryMode = 'tickets', phase = '', refreshing = false, lastSuccess = 0;
let selectedEntity = null;
const entities = () => Array.isArray(data?.entities) ? data.entities : [];
const tracks = () => entities().filter(e => e.kind === 'track' && !e.archived).sort((a,b) => (a.order??999)-(b.order??999) || String(a.title).localeCompare(String(b.title),'zh'));
const problems = () => entities().filter(e => e.kind === 'problem');
const tickets = () => (data?.tickets || []).map(t => ({...t,...(data?.drafts?.tickets?.[t.key] || {})}));
const get = id => entities().find(e => e.id === id);
// 钟点一律按北京时间显示：三台机器系统时区不同，按浏览器本地时区会让同一快照在不同机器上显示成不同钟点
const BJ = {timeZone:'Asia/Shanghai',hour12:false};
const time = iso => { const d = new Date(iso); return Number.isFinite(d.getTime()) ? d.toLocaleString('zh-CN',{...BJ,month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit'}) : '尚未取得'; };
const fullTime = iso => { const d = new Date(iso); return Number.isFinite(d.getTime()) ? d.toLocaleString('zh-CN',{...BJ,year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit'}).replace(/\//g,'-')+'（北京）' : '尚未取得'; };
const age = iso => {const n = Date.now() - new Date(iso).getTime(); return Number.isFinite(n) ? Math.max(0,n/1000) : Infinity;};
const tone = c => ['blue','teal','orange','green','gray','violet'].includes(c) ? c : 'gray';
function notice(text) { $('#notice').textContent=text; $('#notice').hidden=!text; }
async function api(path, options={}) {
  const response = await fetch(path,{...options,headers:{'Content-Type':'application/json',...(options.method ? {'X-Sentinel-Local':'1'} : {}),...options.headers}});
  const body = await response.json();
  if (!response.ok) { const error = new Error(body.error || `请求失败 (${response.status})`); error.status=response.status; throw error; }
  return body;
}
function route() {const raw=location.hash.slice(1); return raw.startsWith('track:') ? 'modules' : (['overview','modules','delivery','rules','connect'].includes(raw) ? raw : 'overview');}
function goModule(id) {currentModule=id; parent='';search='';location.hash='track:'+encodeURIComponent(id);render();}
function head(title,kicker,subtitle='',right='') {return `<div class="page-head"><div><span class="eyebrow">${esc(kicker)}</span><h1>${esc(title)}</h1><div class="subtle">${subtitle}</div></div><div class="toolbar">${right}</div></div>`;}
function section(title,body,right='') {return `<section><div class="section-head"><h2>${esc(title)}</h2><span class="subtle">${right}</span></div>${body}</section>`;}
// ---- 首页主体：问题大屏 ----
// 主体只画五样：页头、四个大数字、状态图例、按分层排的责任域卡片、脚注。
// 数字全部从本次快照的 tickets / domains 现算，不存任何写死的数，换快照就换数。
const DASH_STATES = ['backlog','todo','in_progress','in_review','blocked'];
const FLIGHT = ['in_progress','in_review'];
const BAND_ORDER = ['产品能力','共享底座','交付系统','待分诊'];
const BAND_NOTES = {'产品能力':'按用户结果分工','共享底座':'供多个产品域共同使用','交付系统':'让改动安全到达用户机器','待分诊':'补信息后再分派'};
const openFolds = new Set(); // 30 秒一刷会整页重画，记住哪些折叠被点开过，免得刷一次又合上
let openDomain = '', domainShown = 20; // 首页当前展开的域卡与展开区里已列出的票数
const liveTickets = () => tickets().filter(t=>activeStates.has(t.status));
// 域编号不在登记表里的票并进待分诊，保证各卡张数加起来等于顶上的全部活票
function domainRows(d,live=liveTickets()) {const known=new Set((data?.domains||[]).map(x=>x.id));return live.filter(t=>t.domain===d.id||(d.id==='X'&&!known.has(t.domain)));}
const fmtN = n => Number(n||0).toLocaleString('zh-CN');
const pct = (a,b) => b ? (a/b*100).toFixed(1)+'%' : '0%';
function countStates(rows) {const c=Object.fromEntries(DASH_STATES.map(s=>[s,0]));for(const t of rows)if(t.status in c)c[t.status]++;return c;}
function dashBar(c,sum) {
  const base=sum||1;
  return `<div class="statusbar" role="img" aria-label="${esc(DASH_STATES.map(s=>statusNames[s]+' '+c[s]).join('，'))}">${DASH_STATES.map(s=>c[s]>0?`<span class="s-${s}" style="width:${(100*c[s]/base).toFixed(3)}%" title="${esc(statusNames[s]+' '+c[s])}"></span>`:'').join('')}</div>`;
}
function domainCard(d,rows) {
  const c=countStates(rows), flight=FLIGHT.reduce((a,s)=>a+c[s],0), fn=(Array.isArray(d.functions)?d.functions:[]).filter(Boolean).slice(0,4);
  const breakdown=`<div class="card-breakdown">${DASH_STATES.map(s=>`<span><i class="s-${s}"></i>${esc(statusNames[s])}<b>${fmtN(c[s])}</b></span>`).join('')}</div>`;
  // 卡片整块可点，点开看这个域的票与边界；悬停时功能行换成分状态张数
  const on=d.id===openDomain;
  return `<button type="button" class="domain-card${on?' on':''}" data-domain="${esc(d.id)}" aria-expanded="${on}">`+
    (d.id&&d.name?`<div class="card-top"><span class="domain-id">${esc(d.id)}</span></div>`:'')+
    `<h3>${esc(d.name||d.id)}</h3>`+(d.purpose?`<p class="card-purpose">${esc(d.purpose)}</p>`:'')+
    `<div class="card-swap${fn.length?' flip':''}">${fn.length?`<div class="card-functions">${fn.map(esc).join(' · ')}</div>`:''}${breakdown}</div>`+
    `<div class="card-stats"><strong>${fmtN(rows.length)}</strong> 张<span>${fmtN(flight)} ${FLIGHT.map(s=>statusNames[s]).join(' / ')}</span></div>${dashBar(c,rows.length)}</button>`;
}
// 每个分层按卡数取列数：放得下就一行排完，放不下挑空位最少的列数
function colsFor(n,max) {
  if(n<=max)return n;
  let best=max,gap=Infinity;
  for(let c=max;c>=Math.max(2,Math.ceil(max/2));c--){const e=(c-n%c)%c;if(e<gap){best=c;gap=e;}}
  return best;
}
function layoutBands() {
  const host=$('#bands');if(!host)return;
  const w=host.clientWidth, max=w>=1180?4:w>=860?3:w>=560?2:1;
  host.querySelectorAll('.cards').forEach(el=>{const n=Number(el.dataset.n)||1;el.style.gridTemplateColumns='repeat('+colsFor(n,max)+',minmax(0,1fr))';el.classList.toggle('solo',n===1&&w>=700);});
}
// ---- 就地展开：点哪一格，详情就插在那一格所在行的正下方，占满整行，同行后面和下面的格整体往下挪 ----
// 不用浮层和抽屉，免得挡住别的格、也免得详情落在页面最下面要往下滑才看得到。
const gridCols = grid => Math.max(1,getComputedStyle(grid).gridTemplateColumns.split(/\s+/).filter(t=>/px$/.test(t)).length);
function placeBelowRow(grid,item,panel) {
  const items=[...grid.children].filter(el=>!el.classList.contains('row-detail')), i=items.indexOf(item);
  if(i<0)return;
  const cols=gridCols(grid), last=items[Math.min(items.length-1,(Math.floor(i/cols)+1)*cols-1)];
  // 只跨有格子的那几列：自动铺满的网格里空列会收成零宽，跨进空列会把它们撑开、让这一行的格子变窄
  panel.style.gridColumn='1 / span '+Math.min(cols,items.length);
  if(last.nextElementSibling!==panel)last.after(panel);
}
// 宽度一变列数就变，展开区跟着挪回被点那格所在行的下面
function reflowInline() {
  document.querySelectorAll('.row-detail').forEach(panel=>{
    const grid=panel.parentElement, item=grid&&[...grid.children].find(el=>el!==panel&&(el.dataset.block||el.dataset.domain)===panel.dataset.for);
    if(item)placeBelowRow(grid,item,panel);
  });
}
let gridObserver=null;
function watchGrid(host) {
  if(!host||!('ResizeObserver' in window))return;
  if(!gridObserver)gridObserver=new ResizeObserver(()=>{layoutBands();reflowInline();});
  gridObserver.disconnect();gridObserver.observe(host);
}
function watchBands() {const host=$('#bands');if(!host)return;layoutBands();watchGrid(host);}
function fold(id,title,body) {return `<details class="fold" data-fold="${esc(id)}" ${openFolds.has(id)?'open':''}><summary>${title}<span class="s-c">（点开）</span><span class="s-o">（收起）</span></summary><div class="fold-body">${body}</div></details>`;}
function keepFolds(root=document) {root.querySelectorAll('details[data-fold]').forEach(d=>d.ontoggle=()=>{if(d.open)openFolds.add(d.dataset.fold);else openFolds.delete(d.dataset.fold);});}
function fleet() {
  const native=data?.sentinel||{}, machines=native.machines||[];
  if(!machines.length)return '<div class="muted-box">哨兵尚未取得机器读数；不以工单“进行中”冒充有人在执行。</div>';
  return `<div class="fleet">${machines.map(m=>{
    const stale=age(m.ts)>300, num=v=>typeof v==='number'&&Number.isFinite(v)?Math.round(v):null;
    const cpu=num(m.cpu_pct),mem=num(m.mem_used_pct);
    return `<div class="machine ${stale?'stale':''}"><header><b>${esc(m.id)}</b><span class="subtle">${stale?'旧读数':'最近读数'} · ${time(m.ts)}</span></header><div class="meta">${esc((m.executors||[]).slice(0,3).join(' · ') || '未提供当前执行者')} ${(m.executors||[]).length>3?`等 ${m.executors.length} 位`:''}</div><div class="meter">CPU ${cpu===null?'未知':cpu+'%'} ${cpu===null?'':`<progress value="${cpu}" max="100"></progress>`} 内存 ${mem===null?'未知':mem+'%'}</div></div>`;
  }).join('')}</div><p class="health-hint">读数直接来自哨兵。机器负载不代表交付成果；旧读数不代表机器仍在线。</p>${(native.lines||[]).filter(l=>l.active).length?`<details data-fold="lines" ${openFolds.has('lines')?'open':''}><summary class="subtle">${esc(native.host||'本机')} 的当前执行线 · ${(native.lines||[]).filter(l=>l.active).length}</summary><div class="compact-list">${(native.lines||[]).filter(l=>l.active).slice(0,40).map(l=>`<div class="status-line">${esc(l.id)} · ${esc(l.state)} · ${esc(l.model)} · ${time(l.updated_at)}</div>`).join('')}</div></details>`:''}`;
}
function overview() {
  const live=liveTickets(), total=live.length, c=countStates(live);
  const domains=Array.isArray(data.domains)?data.domains:[], known=new Set(domains.map(d=>d.id));
  const hasX=known.has('X'), orphan=live.filter(t=>!known.has(t.domain)).length;
  const rowsOf=d=>domainRows(d,live);
  const bandOf=d=>d.band||'未分层';
  const bandNames=[...BAND_ORDER,...domains.map(bandOf)].filter((b,i,all)=>all.indexOf(b)===i&&domains.some(d=>bandOf(d)===b));
  const groups=bandNames.map(name=>{const items=domains.filter(d=>bandOf(d)===name).map(d=>({d,rows:rowsOf(d)}));return {name,items,count:items.reduce((a,x)=>a+x.rows.length,0)};});
  const kpis=[
    ['全部活票',total,'含修复、研究、验收、需求与记录'],
    ['待规划',c.backlog,`占活票 ${pct(c.backlog,total)}；仅是库存状态`],
    ['进行中 + 待评审',c.in_progress+c.in_review,`${fmtN(c.in_progress)} + ${fmtN(c.in_review)}；不等同于 ${fmtN(c.in_progress+c.in_review)} 条在跑`],
    ['待办 + 阻塞',c.todo+c.blocked,`${fmtN(c.todo)} + ${fmtN(c.blocked)}；还需要确认负责人和出口`]];
  const src=live.reduce((a,t)=>{const k=t.domain_src==='label'?'label':t.domain_src==='none'?'none':'other';a[k]++;return a;},{label:0,none:0,other:0});
  const foot=`原状态不变。按 Multica 域标签归属 ${fmtN(src.label)} 张；没有域标签的沿用早先快照的建议分流 ${fmtN(src.other)} 张，仍无归属的 ${fmtN(src.none)} 张计入待分诊${orphan?`；另有 ${fmtN(orphan)} 张的域编号不在登记表里，${hasX?'也计入待分诊':'未计入任何卡片'}`:''}。责任人、真运行状态、已部署版本及验收时间不由票单提供，本页均不臆填。`;
  const header=`<header class="header"><div class="header-main"><div class="eyebrow"><span class="brand"><span class="brand-icon" aria-hidden="true">C</span>CORTEX</span><span class="sep" aria-hidden="true"></span><span>PROJECT OWNERSHIP</span></div><h1>Cortex 开发全景</h1><p class="header-sub">${esc(['票单快照 '+fullTime(data.synced_at),'来源 Multica 活票（哨兵同步）',tracks().length+' 个已开工板块'].join(' · '))}</p></div>`+
    `<div class="header-side"><span class="pill">${fmtN(total)} 张活票</span><button id="sync" type="button" class="pill-button">刷新来源</button></div></header>`;
  const kpiRow=`<section class="kpis" style="--kc:4">${kpis.map(([label,value,note])=>`<div class="kpi"><div class="kpi-label">${esc(label)}</div><div class="kpi-number">${fmtN(value)}</div><div class="kpi-note">${esc(note)}</div></div>`).join('')}</section>`;
  const legendBar=`<div class="legendbar"><div class="legend" role="list">${DASH_STATES.map(s=>`<span role="listitem"><i class="s-${s}"></i>${esc(statusNames[s])}<b>${fmtN(c[s])}</b></span>`).join('')}</div><span class="scope-note">${domains.length} 个责任域 · ${groups.length} 个分层</span></div>`;
  const bands=groups.length?`<div class="bands" id="bands">${groups.map((g,i)=>`<section class="band"><div class="band-head"><h2><span class="band-index">${String(i+1).padStart(2,'0')}</span>${esc(g.name)}</h2><small>${esc([fmtN(g.count)+' 张活票',BAND_NOTES[g.name]||''].filter(Boolean).join(' · '))}</small></div><div class="cards" data-n="${g.items.length}">${g.items.map(x=>domainCard(x.d,x.rows)).join('')}</div></section>`).join('')}</div>`:'<p class="empty">还没有登记产品责任域。AI 可先登记板块；不用先把所有模块规划齐。</p>';
  // 主体之下只留两行默认收起的折叠；其余后加的功能走顶栏链接
  const rack=`<div class="module-rack">${tracks().map(t=>`<button data-track="${esc(t.id)}"><b>${esc(t.title)}</b><span>${entities().filter(e=>e.track===t.id&&e.kind==='area'&&!e.archived).length} 块 · ${time(data.sources?.[t.id]?.observed_at||t.updated_at)}</span><span>↗</span></button>`).join('')||'<p class="empty">还没有登记。探索可以从一段自由正文开始。</p>'}</div>`;
  const machines=(data.sentinel?.machines||[]).length;
  const folds=`<div class="dash-folds">${fold('tracks',`已开工的板块 · ${tracks().length} 个`,rack)}${fold('fleet',`正在执行的环境 · ${machines?machines+' 台机器读数':'尚无读数'}`,fleet()+'<p class="health-hint">辅助信息，不作绩效。</p>')}</div>`;
  $('#main').innerHTML=`<div class="dash">${header}${kpiRow}<p class="notice">下图按职责组织现有能力与活跃票，点卡片看该域的票。票数只表示清单规模，不能用来判断模块健康。</p>${legendBar}${bands}<p class="source-foot">${esc(foot)}</p>${folds}</div>`;
  watchBands();keepFolds();
  if(openDomain&&!domains.some(d=>d.id===openDomain))openDomain='';
  if(openDomain)openDomainPanel(false);
  $('#sync').onclick=async()=>{try{await api('/api/refresh',{method:'POST',body:'{}'});notice('正在同步。完整快照回来前保留原来的数。');}catch(e){notice(e.message);}};
}
// ---- 板块图：照板块图模板的 Harness 版式 ----
// 左侧行名 + 右侧块格；块上一枚五档进度签；点块在那块所在行的正下方展开详情；页顶一张「此刻」卡，页尾更新记录默认收起。
// 维护者给的颜色与标签原样显示，不自动算成验收；完整记录、AI 接手文本仍在原来的详情抽屉里。
const TONE_ORDER = ['blue','teal','orange','gray','green','violet'];
let selectedBlock = '';
const historyCache = {events:null, at:0, loading:false};
const chipText = b => String(b.status_label||b.source_label||'').replace(/[（(][^（）()]*[）)]\s*$/,'').trim();
const asText = v => typeof v === 'string' ? v : (v == null ? '' : JSON.stringify(v));
function openBugs(id) {return problems().filter(p=>p.block_id===id&&p.classification==='confirmed_bug'&&!['verified','dismissed'].includes(p.state)).length;}
function blockButton(b,all) {
  const k=tone(b.color||b.source_color), lab=chipText(b), children=all.filter(e=>e.parent===b.id).length, open=openBugs(b.id);
  const note=[b.short_note,children?`${children} 个子块`:'',open?`${open} 个确认缺陷待验`:''].filter(Boolean);
  return `<button type="button" class="blk${b.id===selectedBlock?' on':''}" data-block="${esc(b.id)}" aria-expanded="${b.id===selectedBlock}"><span class="t">${esc(b.title)}</span>${lab?`<span><span class="chip c-${k}">${esc(lab)}</span></span>`:''}${note.length?`<span class="m">${esc(note.join('　'))}</span>`:''}</button>`;
}
function blockDetail(b,all) {
  if(!b)return '';
  const k=tone(b.color||b.source_color), lab=chipText(b), children=all.filter(e=>e.parent===b.id);
  const lead=asText(b.purpose)||asText(b.body), notes=(Array.isArray(b.notes)?b.notes:[]).map(asText).filter(Boolean);
  // 「和谁相连」里的块编号换成同板块里的块名，读的人不用记编号
  const named=asText(b.neighbors).replace(/[A-Za-z0-9_-]+/g,m=>get(b.track+':'+m)?.title||m);
  const refs=(Array.isArray(b.references)?b.references:[b.references]).map(asText).filter(Boolean).join('；');
  const kv=[['还开着',esc(b.short_note)],['现在怎么样',esc(asText(b.source_status_text))],
    ['活票',(b.ticket_ids||[]).map(key=>`<button type="button" class="chip-link" data-ticket="${esc(key)}">${esc(key)}</button>`).join(' ')],
    ['文档/回执',esc(refs)],['归哪条线',esc(asText(b.source_plan))],['和谁相连',esc(named)]].filter(([,v])=>v);
  return `<h3>${esc(b.title)}${lab?`　<span class="chip c-${k}">${esc(lab)}</span>`:''}</h3>`+
    (lead?`<p>${esc(lead)}</p>`:'')+(notes.length?`<ul>${notes.map(n=>`<li>${esc(n)}</li>`).join('')}</ul>`:'')+
    (kv.length?`<div class="kv">${kv.map(([key,v])=>`<div>${key}</div><div>${v}</div>`).join('')}</div>`:'')+
    `<div class="detail-actions">${children.length?`<button type="button" data-drill="${esc(b.id)}">展开下一层 · ${children.length} 块</button>`:''}<button type="button" data-entity="${esc(b.id)}">完整记录与 AI 接手 ↗</button></div>`;
}
function nowCard(track) {
  // 维护者写了 now（字符串 / 字符串数组 / {title,text}）就照写；没写就用板块自己的判断与正文，都没有时明说没写
  let title='此刻的真状态', paras=[];
  const now=track.now;
  if(now&&typeof now==='object'&&!Array.isArray(now)){if(now.title)title=asText(now.title);paras=[].concat(now.text??[]);}
  else if(now!=null)paras=[].concat(now);
  paras=paras.map(asText).filter(p=>p.trim());
  if(!paras.length)paras=[track.status_label,track.body].map(asText).filter(p=>p.trim());
  const at=track.updated_at?`（${time(track.updated_at)}）`:'';
  return `<section class="now" id="now"><h3>${esc(title+at)}</h3>${paras.length?paras.map(p=>`<p>${esc(p)}</p>`).join(''):'<p class="sub">维护者还没写这一块此刻的状态；各块现在怎么样，点块看下方详情。</p>'}</section>`;
}
function historyItems(track,source) {
  const items=[], stamp=v=>new Date(v).getTime()||0;
  if(source.observed_at)items.push({at:source.observed_at,text:'原图更新'+(source.name?' · '+source.name:'')});
  if(Array.isArray(historyCache.events)){
    for(const e of historyCache.events){
      const id=String(e.entity_id||''), body=e.body&&typeof e.body==='object'?e.body:{};
      if(id===track.id||id.startsWith(track.id+':')||body.track===track.id)items.push({at:e.at,text:`${asText(body.title)||id} 改到第 ${e.revision??'?'} 版${e.actor?' · '+e.actor:''}`});
    }
  } else {
    // 维护记录读不到时，退回各条记录自带的最近修订时间
    for(const e of entities())if(e.track===track.id&&e.updated_at)items.push({at:e.updated_at,text:`${asText(e.title)||e.id} 最近一次维护 · 第 ${e.revision||0} 版`});
  }
  return items.sort((a,b)=>stamp(b.at)-stamp(a.at));
}
function paintHistory(track,source) {
  const slot=$('#history-slot');if(!slot)return;
  const items=historyItems(track,source), id='hist:'+track.id;
  if(!items.length){slot.innerHTML='';return;}
  const scope=Array.isArray(historyCache.events)?'只列哨兵最近 100 条维护记录里属于这块的':'维护记录暂时读不到，先列各条记录的最近修订';
  slot.innerHTML=`<details class="hist" id="history" data-fold="${esc(id)}" ${openFolds.has(id)?'open':''}><summary>更新记录 · ${items.length} 次<span class="s-c">（点开）</span><span class="s-o">（收起）</span></summary><div class="inner">${items.slice(0,40).map(x=>`<div><b>${esc(time(x.at))}</b>：${esc(x.text)}</div>`).join('')}<p class="sub hist-note">${scope}${items.length>40?`；只显示最新 40 条`:''}。</p></div></details>`;
  keepFolds(slot);
}
async function loadHistory(track,source) {
  // 维护记录体积大，只在进板块图时读，五分钟内不重读
  if(historyCache.loading||Date.now()-historyCache.at<300000)return;
  historyCache.loading=true;
  try{const body=await api('/api/history');historyCache.events=Array.isArray(body.events)?body.events:[];}catch{historyCache.events=null;}
  finally{historyCache.at=Date.now();historyCache.loading=false;}
  if(route()==='modules'&&currentModule===track.id)paintHistory(track,source);
}
function modulePage() {
  if(location.hash.startsWith('#track:')){const id=decodeURIComponent(location.hash.slice(7));if(currentModule!==id){currentModule=id;parent='';selectedBlock='';}}
  const list=tracks(); if(!get(currentModule))currentModule=list[0]?.id||'';
  const track=get(currentModule), source=data.sources?.[currentModule]||{};
  const picker=`<div class="board-tools"><label>板块 <select id="module-picker">${list.map(t=>`<option value="${esc(t.id)}" ${t.id===currentModule?'selected':''}>${esc(t.title)}</option>`).join('')}</select></label><input id="map-search" type="search" placeholder="找子块、票号或内容" aria-label="搜索板块内容" value="${esc(search)}"></div>`;
  if(!track){$('#main').innerHTML=`<div class="board"><p class="sub stamp">板块图</p><h1>还没有开工资料</h1>${picker}<div class="note">AI 先登记一个入口即可；内部可以边讨论边拆解，不必填满模板。接入方式在“连接”。</div></div>`;return;}
  const all=entities().filter(e=>e.track===currentModule&&e.kind==='area'&&!e.archived);
  let visible=all.filter(e=>search ? JSON.stringify(e).toLowerCase().includes(search.toLowerCase()) : (e.parent||'')===parent);
  const groupOrder=(source.groups||[]).map(g=>g.name), groups=new Map();
  visible.sort((a,b)=>{const ga=groupOrder.indexOf(a.group),gb=groupOrder.indexOf(b.group);return (ga<0?999:ga)-(gb<0?999:gb) || (a.order??999)-(b.order??999);});
  for(const block of visible){const group=block.group||'未分组';if(!groups.has(group))groups.set(group,[]);groups.get(group).push(block);}
  // 默认不展开；点过的块在重画后照旧展开，块不在当前这一层了就收起
  if(selectedBlock&&!visible.some(b=>b.id===selectedBlock))selectedBlock='';
  const rows=[...groups].map(([name,blocks])=>`<div class="row"><div class="rowname">${esc(name)}</div><div class="cells">${blocks.map(b=>blockButton(b,all)).join('')}</div></div>`).join('');
  const ext=!search&&!parent?(source.external||[]).map(asText).filter(Boolean):[];
  const extRow=ext.length?`<div class="row ext"><div class="rowname">别的线<br>只管接缝</div><div class="cells">${ext.map(n=>`<div class="blk"><span class="m">${esc(n)}</span></div>`).join('')}</div></div>`:'';
  const legendRaw=source.legend||track.legend||{}, legendRows=Object.entries(legendRaw&&typeof legendRaw==='object'?legendRaw:{}).filter(([,label])=>asText(label))
    .sort(([a],[b])=>{const ia=TONE_ORDER.indexOf(a),ib=TONE_ORDER.indexOf(b);return (ia<0?99:ia)-(ib<0?99:ib);});
  const relations=entities().filter(e=>e.kind==='relation'&&(e.track===currentModule||get(e.to)?.track===currentModule));
  const freeNotes=entities().filter(e=>e.track===currentModule&&e.kind==='note'&&!e.archived);
  const stamp=[`板块图 · ${all.length} 块`,source.name?'原图更新 '+fullTime(source.observed_at):'维护更新 '+fullTime(track.updated_at),'颜色沿用维护者判断，用户验收另记'].join(' · ');
  $('#main').innerHTML=`<div class="board"><p class="sub stamp">${esc(stamp)}</p><h1>${esc(track.title)}</h1>${track.purpose?`<p class="sub">${esc(asText(track.purpose))}</p>`:''}${picker}`+
    (data.source_errors?.[currentModule]?`<p class="warning">${esc(data.source_errors[currentModule])}</p>`:'')+
    nowCard(track)+
    `<h2 id="sec-map">一、全景：点任意一块看详情</h2>`+
    (parent?`<div class="breadcrumb"><button id="root-map">${esc(track.title)}</button> / ${esc(get(parent)?.title||parent)}</div>`:'')+
    (legendRows.length?`<div class="legend">${legendRows.map(([key,label])=>`<span><i class="dot" style="background:var(--${tone(key)})"></i>${esc(label)}</span>`).join('')}</div>`:'')+
    `<div class="map" id="map" aria-label="${esc(track.title)}结构图">${rows||'<p class="sub">这一层还没有拆分，或没有匹配内容。可以直接阅读板块正文。</p>'}${extRow}</div>`+
    (relations.length?`<div class="seams">${relations.map(r=>`<button data-entity="${esc(r.id)}">${esc(get(r.from)?.title||r.from)}<span class="arrow">↔</span>${esc(get(r.to)?.title||r.to)} <span class="subtle">${r.certainty==='confirmed'?'':'待确认'}</span></button>`).join('')}</div>`:'')+
    `<h2>二、深入这块</h2><div class="module-rack"><button data-entity="${esc(track.id)}">板块正文与 AI 接手 <span>↗</span></button>${freeNotes.map(n=>`<button data-entity="${esc(n.id)}">${esc(n.title)}<span>笔记 ↗</span></button>`).join('')}<button id="module-problems">问题与交付 <span>${problems().filter(p=>p.track===currentModule).length} 条登记 ↗</span></button>${(source.sections||[]).length?'<button id="source-sections">研究、计划与依据 <span>完整原稿内容 ↗</span></button>':''}</div>`+
    `<div id="history-slot"></div></div>`;
  paintHistory(track,source);loadHistory(track,source);
  // 再点同一块收起，点别的块切过去；同一时刻只展开一处
  const setOn=id=>document.querySelectorAll('.board [data-block]').forEach(el=>{const on=el.dataset.block===id;el.classList.toggle('on',on);el.setAttribute('aria-expanded',String(on));});
  const close=()=>{selectedBlock='';setOn('');document.querySelectorAll('.board .row-detail').forEach(p=>p.remove());};
  const open=(id,byUser)=>{
    const btn=[...document.querySelectorAll('.board [data-block]')].find(el=>el.dataset.block===id), b=get(id);
    if(!btn||!b){close();return;}
    selectedBlock=id;setOn(id);
    document.querySelectorAll('.board .row-detail').forEach(p=>{if(p.parentElement!==btn.parentElement)p.remove();});
    let panel=btn.parentElement.querySelector(':scope > .row-detail');
    if(!panel){panel=document.createElement('div');panel.className='detail row-detail';panel.id='block-detail';panel.setAttribute('aria-live','polite');}
    panel.dataset.for=id;panel.innerHTML=blockDetail(b,all);
    placeBelowRow(btn.parentElement,btn,panel);
    bind(panel);panel.querySelectorAll('[data-drill]').forEach(x=>x.onclick=()=>{parent=x.dataset.drill;search='';selectedBlock='';modulePage();bind();});
    if(byUser)panel.scrollIntoView({block:'nearest',behavior:window.matchMedia?.('(prefers-reduced-motion: reduce)').matches?'auto':'smooth'});
  };
  document.querySelectorAll('.board [data-block]').forEach(b=>b.onclick=()=>{if(selectedBlock===b.dataset.block)close();else open(b.dataset.block,true);});
  if(selectedBlock)open(selectedBlock,false);
  watchGrid($('#map'));
  $('#module-picker').onchange=e=>goModule(e.target.value);
  $('#map-search').oninput=e=>{const at=e.target.selectionStart;search=e.target.value;modulePage();bind();$('#map-search').focus();$('#map-search').setSelectionRange(at,at);};
  if($('#root-map'))$('#root-map').onclick=()=>{parent='';selectedBlock='';render();};
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
const TICKET_RANK={blocked:0,in_review:1,in_progress:2,todo:3,backlog:4};
function toggleDomain(id) {
  if(openDomain===id){closeDomainPanel();return;}
  openDomain=id;domainShown=20;openDomainPanel(true);
}
function closeDomainPanel() {
  openDomain='';document.querySelectorAll('.dash .row-detail').forEach(p=>p.remove());
  document.querySelectorAll('.dash .domain-card').forEach(c=>{c.classList.remove('on');c.setAttribute('aria-expanded','false');});
}
function domainPanelHtml(d) {
  const rows=domainRows(d).sort((a,b)=>(TICKET_RANK[a.status]??9)-(TICKET_RANK[b.status]??9)||Number(String(b.key).replace(/\D/g,''))-Number(String(a.key).replace(/\D/g,'')));
  const c=countStates(rows), related=tracks().filter(t=>(t.domains||[]).includes(d.id)), draft=data.drafts?.domains?.[d.id]||{};
  const canSave=info?.local&&data.connection?.mode==='host', rest=rows.length-domainShown;
  const list=rows.slice(0,domainShown).map(t=>`<button type="button" class="tk-row" data-ticket="${esc(t.key)}"><span class="tk-key">${esc(t.key)}</span><span class="tk-title">${esc(t.title)}</span><span class="tk-state"><i class="s-${esc(t.status)}"></i>${esc(statusNames[t.status]||t.status)}</span></button>`).join('');
  return `<div class="dp-head"><div class="dp-title"><span class="domain-id">${esc(d.id)} · ${esc(d.band||'责任域')}</span><h3>${esc(d.name||d.id)} · ${fmtN(rows.length)} 张活票</h3>${d.purpose?`<p class="dp-purpose">${esc(d.purpose)}</p>`:''}</div><button type="button" class="pill-button" data-close-domain>收起</button></div>`+
    `<div class="dp-counts">${DASH_STATES.map(s=>`<span><i class="s-${s}"></i>${esc(statusNames[s])}<b>${fmtN(c[s])}</b></span>`).join('')}</div>${dashBar(c,rows.length)}`+
    `<p class="dp-order">按阻塞、待评审、进行中、待办、待规划排，同状态新票在前；点票号看这张票。</p>`+
    `<div class="dp-list">${list||'<p class="dp-empty">这个域眼下没有活票。</p>'}</div>`+
    (rest>0?`<button type="button" class="pill-button dp-more" data-more-domain>再列 ${fmtN(Math.min(20,rest))} 张（还有 ${fmtN(rest)} 张）</button>`:'')+
    `<div class="dp-meta"><div><b>边界</b>${esc(d.boundary||'尚未记录')}</div><div><b>已开工板块</b>${related.map(t=>`<button type="button" class="chip-link" data-track="${esc(t.id)}">${esc(t.title)} ↗</button>`).join(' ')||'尚未开图，不凭空补齐。'}</div>${(d.docs||[]).length?`<div><b>仓库入口</b>${esc((d.docs||[]).join('；'))}</div>`:''}</div>`+
    `<details class="dp-draft" data-fold="draft:${esc(d.id)}" ${openFolds.has('draft:'+d.id)?'open':''}><summary>负责人与这轮要交付什么（管理草稿）</summary><label class="field">负责人<input id="draft-owner" value="${esc(draft.owner||'')}"></label><label class="field">这轮要交付什么<textarea id="draft-goal">${esc(draft.goal||'')}</textarea></label>${canSave?'<button type="button" id="save-draft">保存管理草稿</button>':'<p class="dp-order">当前连接为浏览权限。</p>'}</details>`;
}
function openDomainPanel(byUser) {
  const d=(data.domains||[]).find(x=>x.id===openDomain), card=[...document.querySelectorAll('.dash .domain-card')].find(el=>el.dataset.domain===openDomain);
  if(!d||!card){openDomain='';return;}
  document.querySelectorAll('.dash .row-detail').forEach(p=>{if(p.parentElement!==card.parentElement)p.remove();});
  let panel=card.parentElement.querySelector(':scope > .row-detail');
  if(!panel){panel=document.createElement('section');panel.className='domain-panel row-detail';panel.setAttribute('aria-live','polite');}
  panel.dataset.for=d.id;panel.id='domain-panel';panel.setAttribute('aria-label',(d.name||d.id)+' 的活票');
  document.querySelectorAll('.dash .domain-card').forEach(c=>{const on=c===card;c.classList.toggle('on',on);c.setAttribute('aria-expanded',String(on));});
  panel.innerHTML=domainPanelHtml(d);
  placeBelowRow(card.parentElement,card,panel);
  wireDomainPanel(panel,d);
  if(byUser)panel.scrollIntoView({block:'nearest',behavior:window.matchMedia?.('(prefers-reduced-motion: reduce)').matches?'auto':'smooth'});
}
function wireDomainPanel(panel,d) {
  bind(panel);keepFolds(panel);
  panel.querySelector('[data-close-domain]').onclick=()=>{const card=[...document.querySelectorAll('.dash .domain-card')].find(el=>el.dataset.domain===d.id);closeDomainPanel();card?.focus();};
  const more=panel.querySelector('[data-more-domain]');
  if(more)more.onclick=()=>{domainShown+=20;panel.innerHTML=domainPanelHtml(d);wireDomainPanel(panel,d);};
  const save=panel.querySelector('#save-draft');
  if(save)save.onclick=async()=>{try{const drafts=JSON.parse(JSON.stringify(data.drafts||{domains:{},tickets:{}}));drafts.domains[d.id]={owner:panel.querySelector('#draft-owner').value,goal:panel.querySelector('#draft-goal').value};await api('/api/drafts',{method:'PUT',body:JSON.stringify({base_revision:data.draft_revision,drafts})});save.textContent='已保存';await refresh(false);}catch(e){notice(e.message);}};
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
  root.querySelectorAll('[data-domain]').forEach(b=>b.onclick=()=>toggleDomain(b.dataset.domain));
  root.querySelectorAll('[data-ticket]').forEach(b=>b.onclick=()=>ticketDetail(b.dataset.ticket));
  root.querySelectorAll('[data-delivery]').forEach(b=>b.onclick=()=>{deliveryMode=b.dataset.delivery;phase='';page=0;search='';render();});
  root.querySelectorAll('[data-phase]').forEach(b=>b.onclick=()=>{phase=b.dataset.phase;page=0;render();});
}
function render() {
  // 视图名挂在根元素上，首页与板块图各按自己的模板取底色和版心宽度
  const view=route();document.documentElement.dataset.view=view;document.querySelectorAll('.mast nav a').forEach(a=>a.classList.toggle('active',a.hash==='#'+view));
  if(view==='rules'){rulesPage();return;}
  if(!data)return;
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
    if(route()==='rules')render();
    if(!data&&e.status===401){$('#main').innerHTML=head('连接共享工作台','需要浏览配对码','在保存共享账的哨兵中，“连接与接入”可查看。')+'<label class="field">浏览配对码<input id="pair-key" type="password" autocomplete="off"></label><button id="pair" class="primary">连接</button>';$('#pair').onclick=async()=>{try{await api('/api/pair',{method:'POST',body:JSON.stringify({key:$('#pair-key').value})});await refresh();}catch(err){notice(err.message);}};}
  }finally{refreshing=false;}
}
$('#close-detail').onclick=()=>{$('#detail').close();selectedEntity=null;};
if(!('ResizeObserver' in window))window.addEventListener('resize',()=>{layoutBands();reflowInline();});
$('#wall').onclick=()=>{document.body.classList.toggle('wall');$('#wall').textContent=document.body.classList.contains('wall')?'退出大屏':'大屏';};
window.addEventListener('hashchange',()=>{search='';page=0;render();});
refresh();setInterval(()=>refresh(),30000);
