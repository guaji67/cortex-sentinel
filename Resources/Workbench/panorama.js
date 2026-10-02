'use strict';
// 全景只投影现有票单和 track 登记，不维护第二份板块或负责人名册。
(function(root) {
  const ACTIVE = new Set(['backlog', 'todo', 'in_progress', 'in_review', 'blocked']);
  const labels = row => [...new Set((row.labels || []).map(x => typeof x === 'string' ? x : x.name).filter(Boolean))];
  const percent = (n, total) => total ? (100 * n / total).toFixed(1) + '%' : '0.0%';
  const newest = rows => [...rows].sort((a,b) => String(b.updated || b.updated_at || '').localeCompare(String(a.updated || a.updated_at || '')));
  function build(snapshot) {
    const all = snapshot.tickets || [], live = all.filter(t => ACTIVE.has(t.status));
    const tracks = (snapshot.entities || []).filter(t => t.kind === 'track' && !t.archived);
    const domains = (snapshot.domains || []).map(d => ({...d, name:d.name || d.label?.slice(2) || d.id}));
    const byKey = new Map(all.map(t => [t.key,t]));
    const byLabel = new Map(domains.map(d => [d.label, d]));
    // 新的域标签也能出现；旧快照建议分流不能代替当前标签。
    for (const t of live) for (const label of labels(t).filter(l => l.startsWith('域:'))) {
      if (!byLabel.has(label)) {
        const d = {id:'label:' + label, label, name:label.slice(2), band:'新登记责任域'};
        domains.push(d); byLabel.set(label,d);
      }
    }
    const primary = t => {
      const matches = labels(t).filter(l => l.startsWith('域:'));
      return matches.length === 1 ? byLabel.get(matches[0])?.id : '__unclassified__';
    };
    const matchesTrack = (t, track) => {
      const selectors = track.ticket_labels || [];
      return selectors.length ? selectors.some(l => labels(t).includes(l)) : (track.domains || []).includes(primary(t));
    };
    const mergeRecords = snapshot.merges?.records || [];
    const summary = (card, rows, related, matches) => {
      const states = Object.fromEntries([...ACTIVE].map(s => [s,rows.filter(t => t.status === s).length]));
      const running = newest(rows.filter(t => t.status === 'in_progress'));
      const blocked = newest(rows.filter(t => t.status === 'blocked'));
      const scopeRelated = related.filter(t => card.track || !(t.ticket_labels || []).some(l => l.startsWith('家族:')) || (t.ticket_labels || []).includes(card.label));
      const owners = [...new Set(scopeRelated.map(t => t.owner).filter(x => typeof x === 'string' && x.trim()))];
      const merged = mergeRecords.filter(m => (m.ticket_keys || []).some(key => byKey.has(key) && matches(byKey.get(key))));
      return {...card, rows, related, states, owners, merged,
        doing: running[0]?.title || scopeRelated.find(t => t.status_label)?.status_label || '票面尚无进行中的工作',
        blocker: blocked[0]?.title || scopeRelated.find(t => t.blocker)?.blocker || '票面未标阻塞，未逐项复验',
        share:percent(rows.length, live.length), runningShare:percent(states.in_progress,rows.length), blockedShare:percent(states.blocked,rows.length)};
    };
    const cards = domains.map(d => {
      const related = tracks.filter(t => (t.domains || []).includes(d.id) || (t.ticket_labels || []).includes(d.label));
      return summary(d,live.filter(t => primary(t) === d.id),related,t => primary(t) === d.id);
    });
    cards.push(summary({id:'__unclassified__',name:'未归类',band:'补标签',purpose:'缺域标签或有多个主域；旧分流不当作已归类。'},
      live.filter(t => primary(t) === '__unclassified__'),[],t => primary(t) === '__unclassified__'));
    const trackCards = tracks.map(t => summary({id:'track:' + t.id,name:t.title,band:'已登记板块',track:t.id},
      live.filter(row => matchesTrack(row,t)),[t],row => matchesTrack(row,t)));
    return {cards,trackCards,live,tracks,primary,percent,labels,activeStates:ACTIVE};
  }
  const api = {build,percent,labels};
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.CortexPanorama = api;
})(typeof window === 'undefined' ? {} : window);
