'use strict';
// Pure calculations are also used by the Node regression checks. No network
// scope is inferred when the server does not supply a numerator/denominator.
const NetworkStatsMath = (() => {
  const finite = n => typeof n === 'number' && Number.isFinite(n);
  const ratio = (a,b,scale=1) => finite(a)&&finite(b)&&b>0 ? a/b*scale : undefined;
  const contiguous = (a,b,bucket=0) => !b.gap_before && b.ts>a.ts && b.ts-a.ts<=Math.max(a.interval*2.5,b.interval*2.5,bucket*2.5);
  function derived(point, previous) {
    const c=point.counts, out={...c};
    out.invisible_pct=ratio(c.invisible_users,c.visible_users+c.invisible_users,100);
    out.visible_pct=ratio(c.visible_users,c.visible_users+c.invisible_users,100);
    out.users_per_channel=ratio(c.users,c.channels);
    out.users_per_server=ratio(c.users,c.servers);
    out.operators_per_1000=ratio(c.operators,c.users,1000);
    out.local_pct=ratio(c.local_users,c.users,100);
    if(finite(point.net_rate)) out.net_rate=point.net_rate;
    else if(previous&&contiguous(previous,point)&&finite(c.users)&&finite(previous.counts.users))
      out.net_rate=(c.users-previous.counts.users)*3600/(point.ts-previous.ts);
    return out;
  }
  function segments(points,key,bucket=0) {
    const result=[];let part=[],last=null;
    for(const p of points){
      if(!finite(p.counts[key])){if(part.length)result.push(part);part=[];last=null;continue;}
      if(last&&!contiguous(last,p,bucket)){if(part.length)result.push(part);part=[];}
      part.push(p);last=p;
    }
    if(part.length)result.push(part);
    return result;
  }
  return Object.freeze({finite,ratio,contiguous,derived,segments});
})();
if(typeof module!=='undefined'&&module.exports) module.exports=NetworkStatsMath;
else (() => {
  const $=id=>document.getElementById(id), M=NetworkStatsMath;
  const stream=location.pathname.split('/').filter(Boolean)[0];
  const nf=new Intl.NumberFormat('fr-FR',{maximumFractionDigits:2});
  const value=n=>M.finite(n)?nf.format(n):'—';
  const signed=n=>M.finite(n)?(n>0?'+':'')+value(n):'—';
  const date=ts=>M.finite(ts)?new Date(ts*1000).toLocaleString('fr-FR'):'—';
  const duration=n=>n>=3600?value(n/3600)+' h':n>=60?value(n/60)+' min':value(n)+' s';
  const names={users:'Utilisateurs',visible_users:'Visibles',invisible_users:'Invisibles',channels:'Canaux formés',operators:'Opérateurs IRC',servers:'Serveurs du réseau',unknown_connections:'Connexions inconnues',local_users:'Clients locaux',local_users_max:'Pic local annoncé (265)',local_servers:'Liens serveurs locaux',global_users:'Total global (266)',users_max:'Pic global annoncé (266)',net_rate:'Variation nette / heure',invisible_pct:'Invisibles %',visible_pct:'Visibles %',users_per_channel:'Utilisateurs / canal',users_per_server:'Utilisateurs / serveur',operators_per_1000:'Opérateurs / 1 000 utilisateurs',local_pct:'Part locale %'};
  const rawKeys=['users','visible_users','invisible_users','channels','operators','servers','global_users','users_max','local_users','local_users_max','local_servers','unknown_connections'];
  const colors={users:'#74bfb4',visible_users:'#86a9dc',invisible_users:'#ae9ccf',channels:'#86a9dc',operators:'#c8ae7b',servers:'#9aaacc',unknown_connections:'#c4909e',local_users:'#74bfb4',local_users_max:'#8f999d',local_servers:'#bdac89',global_users:'#adb6c0',users_max:'#bcaa81',net_rate:'#83bca7',invisible_pct:'#ae9ccf',visible_pct:'#86a9dc',users_per_channel:'#89afb8',users_per_server:'#9aaacc',operators_per_1000:'#c8ae7b',local_pct:'#74bfb4'};
  const configs=[
    ['users','Population du réseau','Visibles, invisibles et total ; pics annoncés disponibles dans la légende.',['users','visible_users','invisible_users','global_users','users_max'],'251 / 266','',true],
    ['channels','Canaux formés','Canaux annoncés par le réseau, sans leurs noms.',['channels'],'254',''],
    ['net','Dynamique de population','Variation nette normalisée par heure, entre observations proches.',['net_rate'],'CALCULÉ','/ h'],
    ['visibility','Répartition des utilisateurs','Proportions calculées sur la somme visible + invisible.',['invisible_pct','visible_pct'],'251','%'],
    ['operators','Opérateurs IRC','Les opérateurs du réseau, distincts des opérateurs de canaux.',['operators'],'252',''],
    ['servers','Topologie annoncée','Serveurs du réseau et liens du serveur de connexion.',['servers','local_servers'],'251 / 255',''],
    ['local','Clients du serveur de connexion','Compteurs locaux ; le pic serveur reste une série distincte.',['local_users','local_users_max'],'255 / 265',''],
    ['unknown','Connexions inconnues','Valeur explicitement annoncée ; une absence reste inconnue.',['unknown_connections'],'253',''],
    ['density','Utilisateurs par serveur','Rapport du total retenu au nombre de serveurs annoncé.',['users_per_server'],'RATIO',''],
    ['channels-ratio','Rapport utilisateurs / canaux','Indicateur global, pas une taille moyenne réelle de canal.',['users_per_channel'],'RATIO',''],
    ['operator-ratio','Présence des opérateurs','Nombre d’opérateurs IRC pour 1 000 utilisateurs.',['operators_per_1000'],'RATIO','']
  ];
  const panels=new Map(),disabled=new Set(['global_users','users_max','local_users_max']);
  let range='24h',data=null,points=[],busy=false,zoom=null,cursor=null,drag=null,raf=0;
  const el=(tag,text,cls)=>{const x=document.createElement(tag);if(text!==undefined)x.textContent=text;if(cls)x.className=cls;return x;};
  function visible(){return zoom?points.filter(p=>p.ts>=zoom[0]&&p.ts<=zoom[1]):points;}
  const bounds=()=>zoom||[data?.from||0,data?.now||1];
  function allDraw(){for(const id of panels.keys())draw(id);}
  function schedule(){if(!raf)raf=requestAnimationFrame(()=>{raf=0;allDraw();});}
  function resetZoom(){zoom=null;drag=null;$('reset-zoom').hidden=true;schedule();}
  for(const [id,title,subtitle,keys,badge,unit,wide] of configs){
    const article=el('article',undefined,'panel'+(wide?' wide':'')),head=el('div',undefined,'panel-heading'),intro=el('div');
    intro.append(el('h2',title),el('p',subtitle));head.append(intro,el('span',badge,'badge'));
    const legend=el('div',undefined,'legend'),plot=el('div',undefined,'plot'),canvas=el('canvas'),tip=el('div',undefined,'tooltip'),meta=el('p',undefined,'chart-meta');
    canvas.id=id;canvas.tabIndex=0;canvas.setAttribute('role','img');canvas.setAttribute('aria-label',title+' ; flèches pour parcourir les observations, Échap pour annuler le zoom. Tableau accessible en bas de page.');
    tip.hidden=true;plot.append(canvas,tip);article.append(head,legend,plot,meta);$('charts').append(article);
    panels.set(id,{canvas,tip,keys,unit,meta});
    for(const key of keys){const b=el('button',names[key]);b.style.setProperty('--accent',colors[key]);b.setAttribute('aria-pressed',String(!disabled.has(key)));b.addEventListener('click',()=>{disabled.has(key)?disabled.delete(key):disabled.add(key);b.setAttribute('aria-pressed',String(!disabled.has(key)));draw(id);});legend.append(b);}
    const timestamp=ev=>{const r=canvas.getBoundingClientRect(),[a,b]=bounds();return a+Math.max(0,Math.min(1,(ev.clientX-r.left-58)/(r.width-72)))*(b-a);};
    canvas.addEventListener('pointermove',ev=>{if(!data)return;cursor=timestamp(ev);if(drag?.id===id)drag.end=cursor;showTip(id,ev.clientX-canvas.getBoundingClientRect().left);schedule();});
    canvas.addEventListener('pointerleave',()=>{tip.hidden=true;if(!drag){cursor=null;schedule();}});
    canvas.addEventListener('pointerdown',ev=>{if(ev.button!==0||!data)return;drag={id,start:timestamp(ev),end:timestamp(ev)};canvas.setPointerCapture(ev.pointerId);});
    canvas.addEventListener('pointerup',ev=>{if(drag?.id!==id)return;const [a,b]=[drag.start,drag.end].sort((x,y)=>x-y);drag=null;const found=points.filter(p=>p.ts>=a&&p.ts<=b);if(b-a>(bounds()[1]-bounds()[0])*.015&&found.length>=2){zoom=[a,b];$('reset-zoom').hidden=false;}if(canvas.hasPointerCapture(ev.pointerId))canvas.releasePointerCapture(ev.pointerId);schedule();});
    canvas.addEventListener('pointercancel',()=>{drag=null;cursor=null;tip.hidden=true;schedule();});
    canvas.addEventListener('dblclick',resetZoom);
    canvas.addEventListener('keydown',ev=>{if(ev.key==='Escape'){resetZoom();return;}if(!['ArrowLeft','ArrowRight'].includes(ev.key)||!visible().length)return;ev.preventDefault();const ps=visible();let idx=cursor===null?0:ps.findIndex(p=>p.ts>=cursor);idx=Math.max(0,Math.min(ps.length-1,idx+(ev.key==='ArrowLeft'?-1:1)));cursor=ps[idx].ts;showTip(id,80);schedule();});
    new ResizeObserver(schedule).observe(plot);
  }
  function showTip(id,left){
    const {tip,keys,canvas,unit}=panels.get(id),ps=visible();if(!ps.length)return;
    const p=ps.reduce((best,x)=>Math.abs(x.ts-cursor)<Math.abs(best.ts-cursor)?x:best);
    tip.replaceChildren(el('strong',date(p.ts)));
    for(const key of keys)if(!disabled.has(key)){const row=el('div');row.append(el('span',names[key]),el('b',value(p.counts[key])+(M.finite(p.counts[key])&&unit?' '+unit:'')));tip.append(row);}
    tip.hidden=false;tip.style.left=Math.max(3,Math.min(canvas.clientWidth-tip.offsetWidth-3,left+12))+'px';tip.style.top='12px';
  }
  function draw(id){
    const {canvas,keys:allKeys,unit,meta}=panels.get(id),r=canvas.getBoundingClientRect(),dpr=Math.min(window.devicePixelRatio||1,3);
    canvas.width=Math.round(r.width*dpr);canvas.height=Math.round(r.height*dpr);const c=canvas.getContext('2d');c.scale(dpr,dpr);
    const w=r.width,h=r.height,L=58,R=14,T=17,B=31,[from,to]=bounds(),ps=visible(),keys=allKeys.filter(k=>!disabled.has(k));
    c.font='10px system-ui';c.fillStyle='#8699b0';if(!data)return;
    const vals=ps.flatMap(p=>keys.map(k=>p.counts[k]).filter(M.finite));
    if(!vals.length){c.textAlign='center';c.fillText(!data.samples?'En attente des premières observations':keys.length?'Compteur non fourni sur cette période':'Séries masquées dans la légende',w/2,h/2);meta.textContent='—';return;}
    const top=Math.max(...vals),bottom=Math.min(...vals),pad=Math.max(unit==='%'?1:.1,(top-bottom)*.13);
    let low=bottom<0?bottom-pad:Math.max(0,bottom-pad),high=Math.max(low+1,top+pad);
    if($('zero').checked){low=Math.min(0,low);high=Math.max(0,high);}if(unit==='%'){low=Math.max(0,low);high=Math.min(100,high);if(high<=low)high=low+1;}
    const x=t=>L+(t-from)/(to-from)*(w-L-R),y=v=>h-B-(v-low)/(high-low)*(h-T-B);
    c.strokeStyle='#263448';c.lineWidth=.7;c.textAlign='right';
    for(let i=0;i<=4;i++){const v=low+(high-low)*i/4,yy=y(v);c.beginPath();c.moveTo(L,yy);c.lineTo(w-R,yy);c.stroke();const label=Math.abs(v)>=10000?nf.format(v/1000)+'k':nf.format(Math.round(v*10)/10);c.fillText(label,L-8,yy+3);}
    c.textAlign='center';for(let i=0;i<=4;i++){const t=from+(to-from)*i/4,dt=new Date(t*1000);const label=to-from>86400?dt.toLocaleDateString('fr-FR',{day:'2-digit',month:'2-digit'}):dt.toLocaleTimeString('fr-FR',{hour:'2-digit',minute:'2-digit'});c.fillText(label,Math.max(25,Math.min(w-25,x(t))),h-7);}
    if(low<0&&high>0){c.strokeStyle='#6b7b8d';c.beginPath();c.moveTo(L,y(0));c.lineTo(w-R,y(0));c.stroke();}
    c.save();c.beginPath();c.rect(L,T,w-L-R,h-T-B);c.clip();
    for(const key of keys){const col=colors[key],dashed=key.endsWith('_max')||key==='global_users';c.strokeStyle=col;c.lineWidth=key==='users'?2.1:1.6;c.setLineDash(dashed?[5,4]:[]);
      for(const segment of M.segments(ps,key,data.bucket_seconds)){
        c.beginPath();segment.forEach((p,i)=>i?c.lineTo(x(p.ts),y(p.counts[key])):c.moveTo(x(p.ts),y(p.counts[key])));c.stroke();
        if(!dashed&&segment.length>1){const gradient=c.createLinearGradient(0,T,0,h-B);gradient.addColorStop(0,col+'20');gradient.addColorStop(1,col+'02');c.lineTo(x(segment.at(-1).ts),h-B);c.lineTo(x(segment[0].ts),h-B);c.closePath();c.fillStyle=gradient;c.fill();}
        c.fillStyle=col;for(const p of segment)if(segment.length<4){c.beginPath();c.arc(x(p.ts),y(p.counts[key]),2.5,0,Math.PI*2);c.fill();}
      }
    }c.setLineDash([]);
    if(cursor!==null&&cursor>=from&&cursor<=to){c.strokeStyle='#a8b6ca66';c.beginPath();c.moveTo(x(cursor),T);c.lineTo(x(cursor),h-B);c.stroke();}
    if(drag?.id===id){c.fillStyle='#90b4d522';c.fillRect(x(drag.start),T,x(drag.end)-x(drag.start),h-T-B);}c.restore();
    const key=keys[0],s=!zoom?data.summary[key]:null,vs=ps.map(p=>p.counts[key]).filter(M.finite);
    meta.replaceChildren();if(s)meta.append('MIN ',el('b',value(s.min)),'   MOY ',el('b',value(s.mean)),'   MAX ',el('b',value(s.max)),'   Δ ',el('b',signed(s.delta)));
    else if(vs.length)meta.append(zoom?'ZOOM · ':'CALCULÉ · ','MIN ',el('b',value(Math.min(...vs))),'   MAX ',el('b',value(Math.max(...vs))),unit?' '+unit:'');
    else meta.textContent='Série principale absente sur cette période';
  }
  function spark(canvas,key){
    const c=canvas.getContext('2d'),w=180,h=78;canvas.width=w;canvas.height=h;
    const vals=points.map(p=>p.counts[key]).filter(M.finite);if(!vals.length)return;
    const min=Math.min(...vals),max=Math.max(...vals),span=Math.max(1,max-min),x=t=>3+(t-data.from)/(data.now-data.from)*(w-6),y=v=>h-4-(v-min)/span*(h-8);
    c.strokeStyle=colors[key];c.lineWidth=2;c.beginPath();for(const part of M.segments(points,key,data.bucket_seconds)){part.forEach((p,i)=>i?c.lineTo(x(p.ts),y(p.counts[key])):c.moveTo(x(p.ts),y(p.counts[key])));}c.stroke();
  }
  function render(){
    const latest=data.latest,c=latest?.counts||{},age=latest?Math.max(0,data.now-latest.ts):null,stale=!latest||age>Math.max(900,latest.interval*3);
    points=data.points.map((p,i)=>({...p,counts:M.derived(p,i?data.points[i-1]:null)}));
    $('title').textContent=data.label;document.title=data.label+' · Mediabot Network Observatory';
    $('subtitle').textContent=latest?`${latest.network} · /LUSERS toutes les ${value(latest.interval/60)} min · Horaires du navigateur`:'Historique prêt · En attente du premier échantillon IRC';
    $('status').className='status '+(stale?'stale':'fresh');$('status').querySelector('span').textContent=latest?(stale?'Collecte en retard':'Données récentes')+' · '+duration(age):'En attente de données';
    $('notice').hidden=!stale;$('notice').textContent=latest?'La collecte est en retard. Les valeurs restent celles de la dernière observation ; vérifier la connexion IRC et la publication.':'Aucune donnée reçue pour cette instance. L’historique commencera avec les prochains échantillons.';
    $('cards').replaceChildren();
    for(const [idx,key] of ['users','channels','operators','servers'].entries()){
      const card=el('article',undefined,'card'),head=el('div',undefined,'card-top'),cv=el('canvas',undefined,'card-spark'),s=data.summary[key];card.style.setProperty('--accent',colors[key]);
      cv.setAttribute('aria-hidden','true');head.append(el('span',names[key],'card-label'),el('span','0'+(idx+1),'card-index'));card.append(head,el('div',value(c[key]),'card-value'),cv);
      card.append(el('div',s?`${signed(s.delta)} sur la période${M.finite(s.delta_percent)?' · '+signed(s.delta_percent)+' %':''}`:'Aucune mesure sur la période','card-foot'));$('cards').append(card);spark(cv,key);
    }
    const q=data.quality||{};$('telemetry').replaceChildren();
    for(const [label,text] of [['Échantillons',value(data.samples)],['Couverture mesurée',value(q.coverage_percent)+' %'],['Trous entre mesures',value(q.gaps)],['Dernière observation',latest?new Date(latest.ts*1000).toLocaleTimeString('fr-FR'):'—']]){const block=el('div');block.append(el('small',label),el('b',text));$('telemetry').append(block);}
    $('details').replaceChildren();
    for(const key of rawKeys){const s=data.summary[key],tr=el('tr'),label=el('td');label.append(el('span',names[key]),el('small',key,'scope'));if(s)label.title=`Première : ${date(s.first_at)} · Dernière : ${date(s.last_at)} · Pic : ${date(s.max_at)}`;tr.append(label,el('td',value(c[key])),el('td',s?signed(s.delta):'—'));for(const k of ['min','mean','max','median','p95','stddev','n']){const cell=el('td',value(s?.[k]));if(k==='max'&&s)cell.append(el('small',new Date(s.max_at*1000).toLocaleString('fr-FR',{day:'2-digit',month:'2-digit',hour:'2-digit',minute:'2-digit'})));tr.append(cell);}$('details').append(tr);}
    const header=el('tr');header.append(el('th','Observation'));for(const key of rawKeys)header.append(el('th',names[key]));$('observations').querySelector('thead').replaceChildren(header);
    const body=$('observations').querySelector('tbody');body.replaceChildren();for(const p of data.points){const row=el('tr');row.append(el('td',date(p.ts)));for(const key of rawKeys)row.append(el('td',value(p.counts[key])));body.append(row);}
    $('resolution').textContent=`${value(data.samples)} mesures brutes · ${value(data.points.length)} observations affichées · intervalle d’affichage ${duration(data.bucket_seconds)} · conservation 90 jours. Les courbes longues gardent la dernière observation réelle de chaque intervalle ; les statistiques utilisent toutes les mesures. Plus grand trou intérieur : ${duration(q.longest_gap_seconds||0)}.`;
    $('networks').replaceChildren();for(const n of data.streams||[]){const a=el('a',n.label);a.href='/'+encodeURIComponent(n.id);if(n.id===stream)a.setAttribute('aria-current','page');$('networks').append(a);}
    $('updated').textContent='Actualisé à '+new Date(data.now*1000).toLocaleTimeString('fr-FR')+' · '+Intl.DateTimeFormat().resolvedOptions().timeZone+' · 60 s';allDraw();
  }
  async function refresh(){if(busy)return;busy=true;$('refresh').disabled=true;
    try{const r=await fetch('/'+encodeURIComponent(stream)+'/data?range='+range,{cache:'no-store',signal:AbortSignal.timeout(10000)});if(!r.ok)throw Error();const incoming=await r.json();if(!Array.isArray(incoming.points)||!incoming.summary)throw Error();data=incoming;render();}
    catch{$('notice').hidden=false;$('notice').textContent='Données indisponibles pour le moment. Les dernières valeurs affichées sont conservées ; nouvelle tentative automatique dans une minute.';$('status').className='status stale';$('status').querySelector('span').textContent='Publication indisponible';}
    finally{busy=false;$('refresh').disabled=false;}
  }
  for(const b of document.querySelectorAll('[data-range]'))b.addEventListener('click',()=>{if(busy)return;range=b.dataset.range;resetZoom();for(const p of document.querySelectorAll('[data-range]'))p.setAttribute('aria-pressed',String(p===b));refresh();});
  $('export').addEventListener('click',()=>{if(!data)return;const rows=[['timestamp_utc',...rawKeys],...data.points.map(p=>[new Date(p.ts*1000).toISOString(),...rawKeys.map(k=>p.counts[k]??'')])];const url=URL.createObjectURL(new Blob([rows.map(r=>r.join(',')).join('\r\n')+'\r\n'],{type:'text/csv;charset=utf-8'}));const a=el('a');a.href=url;a.download=`mediabot-${stream}-${data.range}-observations.csv`;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);});
  $('zero').addEventListener('change',allDraw);$('reset-zoom').addEventListener('click',resetZoom);$('refresh').addEventListener('click',refresh);
  refresh();setInterval(()=>{if(!document.hidden&&!drag)refresh();},60000);
})();
