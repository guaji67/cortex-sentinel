'use strict';
let aiState=null;
const aiPost=(path,body={})=>api('/api/ai/'+path,{method:'POST',body:JSON.stringify(body)});
const aiLabels={installed:'已安装',conflict:'本机差异',skill:'Skill',hook:'Hook'};
async function rulesPage(){
  if(!info?.local){$('#main').innerHTML=head('AI 规则','SKILL · HOOK','安装权限留在目标机器。请在那台电脑打开本机哨兵。');return;}
  try{
    aiState=await api('/api/ai/status');
    if(route()!=='rules')return;
    const peers=aiState.peers||[], machines=[{id:'local',name:'本机',installed:aiState.installed,inventory:aiState.inventory,at:new Date().toISOString()},...peers.map(p=>({id:p.id,name:p.catalog?.machine||p.id,installed:p.catalog?.installed||[],inventory:p.catalog?.inventory,at:p.last_success,error:p.error}))];
    const packages=new Map();
    const addPackage=(p,source)=>{const key=p.id+'/'+(p.digest||source),existing=packages.get(key);if(existing){existing.sources.push(source);return;}packages.set(key,{...p,source,sources:[source]});};
    for(const p of aiState.packages||[])addPackage(p,'local');
    for(const peer of peers)for(const p of peer.catalog?.packages||[])addPackage(p,peer.id);
    const cells=p=>machines.map(m=>{const installed=m.installed.find(i=>i.id===p.id),existing=(m.inventory?.skills||[]).filter(s=>s.id===p.id);
      return `<td>${installed?`<span class="rule-state ${installed.state==='conflict'?'conflict':installed.digest===p.digest?'installed':'pending'}">${esc(installed.state==='conflict'?'本机差异':installed.digest===p.digest?'版本一致':'版本不同')}</span><small>${esc(installed.activation||'尚无调用证据')}</small>`:existing.length?`<span class="rule-state pending">已有入口 · 未接管</span><small>${esc([...new Set(existing.map(s=>s.host))].join(' / '))}</small>`:'<span class="subtle">未安装</span>'}${m.error||age(m.at)>420?'<small class="rule-warning">旧读数 · 不代表当前状态</small>':''}</td>`;}).join('');
    $('#main').innerHTML=head('AI 规则','正本 → 安装 → 调用','按包管理，不绑定机器分工。版本一致不等于 AI 已经使用。','<button id="ai-sync">刷新局域网</button>')+
      `<div class="rule-summary"><span><b>${packages.size}</b> 份已登记规则</span><span><b>${machines.length}</b> 台已连接机器</span><span><b>${aiState.installed.filter(x=>x.state==='conflict'||x.error).length}</b> 处本机待处理</span></div>`+
      `<div class="table-scroll"><table class="ticket-table rules-table"><thead><tr><th>规则 / 正本</th>${machines.map(m=>`<th>${esc(m.name)}<small>${esc(time(m.at))}</small></th>`).join('')}<th>本机操作</th></tr></thead><tbody>${[...packages.values()].map(p=>`<tr><td><span class="rule-kind ${p.kind}">${esc(aiLabels[p.kind]||'未知')}</span><b>${esc(p.title||p.id)}</b><small>${esc(p.id)} · 来源 ${esc(p.sources.map(s=>s==='local'?'本机':s).join(' / '))}</small>${p.error?`<small class="rule-warning">${esc(p.error)}</small>`:''}</td>${cells(p)}<td><button data-rule-source="${esc(p.source)}" data-rule-id="${esc(p.id)}" ${p.error?'disabled':''}>查看 / 安装</button></td></tr>`).join('')||'<tr><td colspan="4">尚未登记规则。下面可以登记现有 Skill，正文和目录结构保持不变。</td></tr>'}</tbody></table></div>`+
      section('本机维护',`<div class="rule-receipts">${aiState.installed.map(i=>`<div><b>${esc(i.title||i.id)}</b><span>${esc((i.targets||[]).join(' / ')||'Claude Hook')} · ${i.automatic?'自动更新':'固定版本'}</span><code>${esc(i.digest.slice(0,12))}</code><span>${esc(i.activation)}</span>${i.error?`<span class="rule-warning">${esc(i.error)}</span>`:''}${i.automatic?`<button data-rule-pause="${esc(i.id)}">暂停更新</button>`:''}${i.previous?`<button data-rule-rollback="${esc(i.id)}">回退上一版</button>`:''}</div>`).join('')||'<p class="subtle">还没有由哨兵接管的安装。</p>'}</div>`)+
      `<details class="rule-setup"><summary>接入来源与登记规则</summary><div class="connect-grid"><section><h2>连接另一台哨兵</h2><label class="field">来源名称<input id="rule-peer-id" placeholder="自选英文短名"></label><label class="field">局域网地址<input id="rule-peer-url" placeholder="http://电脑名.local:8935"></label><label class="field">对端浏览配对码<input id="rule-peer-token" type="password" autocomplete="off"></label><label class="field">对端公钥（需与那台机器核对）<input id="rule-peer-key"></label><button id="rule-add-peer">确认来源</button><p class="subtle">本机公钥：</p><code class="rule-key">${esc(aiState.public_key)}</code></section><section><h2>登记本机正本</h2><p class="subtle">只发布列出的文件；不搬走原稿，不自动发布整个文件夹。</p><label class="field">包 ID<input id="rule-source-id" placeholder="例如 management-roles"></label><label class="field">显示名<input id="rule-source-title"></label><label class="field">正本绝对目录<input id="rule-source-root"></label><label class="field">文件清单（每行一个相对路径）<textarea id="rule-source-files" rows="4">SKILL.md</textarea></label><button id="rule-add-source">登记 Skill</button><p class="subtle">Hook 使用协议登记事件、解释器和入口，预览后单独启用。<a href="#connect">查看接入说明</a></p></section></div></details>`+
      `<details class="rule-setup"><summary>未接管的现有安装 · 本机盘点</summary><p class="subtle">${esc(aiState.inventory.scope)}。只读取名称和摘要，不上传配置或脚本。</p><div class="toolbar">${aiState.inventory.hooks.map(h=>`<span class="chip">${esc(h.event)} · ${h.groups} 组</span>`).join('')||'用户级没有 Hook'}${aiState.inventory.hooks_disabled?' · 用户级总开关已关闭':''}</div><div class="rule-inventory">${aiState.inventory.skills.filter(s=>!s.managed).map(s=>`<span>${esc(s.id)} <small>${esc(s.host)}</small></span>`).join('')}</div></details>`;
    $('#ai-sync').onclick=async()=>{try{$('#ai-sync').disabled=true;await aiPost('sync');await rulesPage();}catch(e){notice(e.message);}};
    if(aiState.startup_error||(aiState.incomplete_installs||[]).length)notice(aiState.startup_error||'存在中断的安装：'+aiState.incomplete_installs.join('、')+'。正本和备份保留；不能视为同步成功。');
    document.querySelectorAll('[data-rule-id]').forEach(b=>b.onclick=()=>previewRule(b.dataset.ruleSource,b.dataset.ruleId));
    const runtime=document.createElement('div');runtime.className='muted-box';runtime.textContent='工程 Hook 沿用哨兵已有 GateRuntime：'+(aiState.gate_runtime?.text||'尚未取得读数')+'。这里不复制或重新开启旧闸。';$('#main').append(runtime);
    const projectInventory=document.createElement('div');projectInventory.className='subtle';projectInventory.textContent=(aiState.inventory.project_hooks||[]).map(p=>p.scope+'：'+(p.error||Object.entries(p.events||{}).map(([e,n])=>e+' '+n+' 组').join(' · '))).join('；');document.querySelector('.rule-setup:last-of-type').append(projectInventory);
    if(aiState.inventory.hooks_error){const warning=document.createElement('p');warning.className='rule-warning';warning.textContent=aiState.inventory.hooks_error;projectInventory.append(warning);}
    document.querySelectorAll('[data-rule-pause]').forEach(b=>b.onclick=async()=>{try{await aiPost('pause',{id:b.dataset.rulePause});await rulesPage();}catch(e){notice(e.message);}});
    document.querySelectorAll('[data-rule-rollback]').forEach(b=>b.onclick=async()=>{if(!confirm('回退到上一份已安装版本，并暂停自动更新？'))return;try{await aiPost('rollback',{id:b.dataset.ruleRollback});await rulesPage();}catch(e){notice(e.message);}});
    document.querySelectorAll('.rule-receipts>div').forEach((row,index)=>{const installed=aiState.installed[index];const button=document.createElement('button');button.textContent='停用';button.onclick=async()=>{if(!confirm('仅停用哨兵拥有的入口，保留正本和历史版本？'))return;try{await aiPost('uninstall',{id:installed.id});await rulesPage();}catch(e){notice(e.message);}};row.append(button);});
    $('#rule-add-peer').onclick=async()=>{try{await aiPost('peer',{id:$('#rule-peer-id').value,url:$('#rule-peer-url').value,token:$('#rule-peer-token').value,public_key:$('#rule-peer-key').value});await aiPost('sync');await rulesPage();}catch(e){notice(e.message);}};
    $('#rule-add-source').onclick=async()=>{try{await aiPost('source',{id:$('#rule-source-id').value,title:$('#rule-source-title').value,kind:'skill',root:$('#rule-source-root').value,files:$('#rule-source-files').value.split('\n').map(x=>x.trim()).filter(Boolean)});await rulesPage();}catch(e){notice(e.message);}};
  }catch(e){notice(e.message);}
}
async function previewRule(source,id){
  try{
    const result=await aiPost('preview',{source,id}),p=result.package,isHook=p.kind==='hook';
    const decode=s=>{try{return new TextDecoder().decode(Uint8Array.from(atob(s),c=>c.charCodeAt(0)));}catch{return '[二进制资源]';}};
    show(p.title||id,`${isHook?'Hook':'Skill'} · ${source} · ${result.digest.slice(0,12)}`,
      `<p>${esc(result.warning)}</p>${source==='local'?`<p class="subtle">本机来源：${esc(aiState.local_sources?.find(s=>s.id===id)?.root||'尚未取得')}。随包协议通过哨兵更新，不直接改 App。</p>`:''}${isHook?`<p>触发事件：<b>${esc(p.hook.event)}</b> · ${esc(p.hook.interpreter)} · ${esc(p.hook.entry)}</p>`:''}`+
      Object.entries(p.files).map(([name,body])=>`<details ${name==='SKILL.md'||name===p.hook?.entry?'open':''}><summary>${esc(name)}</summary><pre class="rule-code">${esc(decode(body))}</pre></details>`).join('')+
      `<div class="toolbar">${!isHook?aiState.hosts.map(h=>`<label><input type="checkbox" name="rule-target" value="${esc(h)}" ${(aiState.installed.find(i=>i.id===id)?.targets||['claude','codex']).includes(h)?'checked':''}> ${esc(h)}</label>`).join(''):''}</div>`+
      (isHook?'<label class="field"><span><input id="rule-hook-approve" type="checkbox">我已核对本版本，允许此 Hook 在本机执行</span></label>':'<label class="field"><span><input id="rule-auto" type="checkbox">订阅这个已确认来源的后续版本（遇到本机修改会停下）</span></label>')+
      '<button class="primary" id="rule-install">安装此版本</button><p id="rule-result" role="status"></p>');
    $('#rule-install').onclick=async()=>{try{
      const answer=await aiPost('install',{id,source,digest:result.digest,targets:[...document.querySelectorAll('[name="rule-target"]:checked')].map(x=>x.value),automatic:$('#rule-auto')?.checked||false,approve_hook:$('#rule-hook-approve')?.checked||false});
      $('#rule-result').textContent=answer.activation;await rulesPage();
    }catch(e){$('#rule-result').textContent=e.message;}};
  }catch(e){notice(e.message);}
}
