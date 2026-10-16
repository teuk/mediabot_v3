'use strict';
(() => {
  const $ = id => document.getElementById(id);
  const stream = location.pathname.split('/').filter(Boolean)[0];
  const fmt = new Intl.NumberFormat('fr-FR');
  const value = n => typeof n === 'number' && Number.isFinite(n) ? fmt.format(n) : '—';
  const date = ts => new Date(ts * 1000).toLocaleString('fr-FR');
  const colors = {users:'#56d9d4',visible_users:'#739bff',invisible_users:'#b496ff',channels:'#739bff',operators:'#ffc76b',servers:'#ff8ba6',local_users:'#56d9d4',unknown_connections:'#ffc76b'};
  const names = {users:'Utilisateurs',visible_users:'Visibles',invisible_users:'Invisibles',channels:'Canaux',operators:'Opérateurs IRC',servers:'Serveurs',local_users:'Utilisateurs locaux',unknown_connections:'Connexions inconnues',local_servers:'Liens serveurs locaux',users_max:'Pic global annoncé',local_users_max:'Pic local annoncé',global_users:'Total global (266)'};
  let range = '24h', data = null, busy = false;
  const panels = {users:['users','visible_users','invisible_users'],channels:['channels'],infrastructure:['operators','servers'],local:['local_users','unknown_connections']};
  const disabled = new Set();
  function el(tag, text, cls) {const x=document.createElement(tag); if (text!==undefined) x.textContent=text; if(cls)x.className=cls; return x;}
  for (const [panel, keys] of Object.entries(panels)) {
    for (const key of keys) {
      const button=el('button',names[key]);button.style.setProperty('--accent',colors[key]);button.setAttribute('aria-pressed','true');
      button.addEventListener('click',()=>{disabled.has(key)?disabled.delete(key):disabled.add(key);button.setAttribute('aria-pressed',String(!disabled.has(key)));draw(panel);});
      $(panel+'-legend').append(button);
    }
    const canvas=$(panel),tip=canvas.parentElement.querySelector('.tooltip');
    canvas.addEventListener('pointermove',ev=>{
      if(!data?.points.length)return;
      const box=canvas.getBoundingClientRect(),t=data.from+Math.max(0,Math.min(1,(ev.clientX-box.left-48)/(box.width-60)))*(data.now-data.from);
      const p=data.points.reduce((best,x)=>Math.abs(x.ts-t)<Math.abs(best.ts-t)?x:best);
      tip.replaceChildren(el('strong',date(p.ts)));
      for(const key of keys)if(!disabled.has(key))tip.append(el('div',`${names[key]} : ${value(p.counts[key])}`));
      tip.hidden=false;tip.style.left=Math.max(4,Math.min(box.width-tip.offsetWidth-4,ev.clientX-box.left+12))+'px';tip.style.top='18px';
    });canvas.addEventListener('pointerleave',()=>{tip.hidden=true;});
    new ResizeObserver(()=>draw(panel)).observe(canvas.parentElement);
  }
  function draw(panel) {
    const canvas=$(panel),box=canvas.getBoundingClientRect(),dpr=window.devicePixelRatio||1;
    canvas.width=Math.round(box.width*dpr);canvas.height=Math.round(box.height*dpr);
    const ctx=canvas.getContext('2d');ctx.scale(dpr,dpr);
    const w=box.width,h=box.height,L=48,R=12,T=16,B=28;
    if(!data)return;
    const keys=panels[panel].filter(x=>!disabled.has(x));
    const vals=data.points.flatMap(p=>keys.map(k=>p.counts[k]).filter(Number.isFinite));
    ctx.font='10px system-ui';ctx.fillStyle='#8293ac';
    if(!vals.length){ctx.textAlign='center';ctx.fillText(data.samples?'Compteur non fourni par le serveur':'En attente des premières observations',w/2,h/2);return;}
    const top=Math.max(...vals),bottom=Math.min(...vals),pad=Math.max(1,(top-bottom)*.12);
    const low=Math.max(0,Math.floor(bottom-pad)),high=Math.max(low+1,Math.ceil(top+pad));
    const x=t=>L+(t-data.from)/(data.now-data.from)*(w-L-R),y=v=>h-B-(v-low)/(high-low)*(h-T-B);
    ctx.lineWidth=1;ctx.strokeStyle='#263144';ctx.textAlign='right';
    for(let i=0;i<=4;i++){const v=low+(high-low)*i/4,yy=y(v);ctx.beginPath();ctx.moveTo(L,yy);ctx.lineTo(w-R,yy);ctx.stroke();ctx.fillText(value(Math.round(v)),L-9,yy+3);}
    ctx.textAlign='center';
    for(let i=0;i<=4;i++){const ts=data.from+(data.now-data.from)*i/4,dt=new Date(ts*1000);const label=(data.now-data.from>86400)?dt.toLocaleDateString('fr-FR',{day:'2-digit',month:'2-digit'}):dt.toLocaleTimeString('fr-FR',{hour:'2-digit',minute:'2-digit'});ctx.fillText(label,Math.max(25,Math.min(w-25,x(ts))),h-5);}
    for(const key of keys){
      const col=colors[key];ctx.strokeStyle=col;ctx.lineWidth=1.8;let last=null,segment=[];
      const paint=()=>{if(!segment.length)return;ctx.beginPath();segment.forEach((p,i)=>i?ctx.lineTo(x(p.ts),y(p.counts[key])):ctx.moveTo(x(p.ts),y(p.counts[key])));ctx.stroke();
        if(segment.length>1){const end=segment.at(-1),start=segment[0],grad=ctx.createLinearGradient(0,T,0,h-B);grad.addColorStop(0,col+'26');grad.addColorStop(1,col+'00');ctx.lineTo(x(end.ts),h-B);ctx.lineTo(x(start.ts),h-B);ctx.closePath();ctx.fillStyle=grad;ctx.fill();}
        ctx.fillStyle=col;for(const p of segment){ctx.beginPath();ctx.arc(x(p.ts),y(p.counts[key]),segment.length<4?3:1.5,0,Math.PI*2);ctx.fill();}segment=[];};
      for(const p of data.points){if(!Number.isFinite(p.counts[key])){paint();last=null;continue;}if(last&&p.ts-last.ts>Math.max(p.interval*2.5,data.bucket_seconds*2.5))paint();segment.push(p);last=p;}paint();
    }
  }
  function render() {
    $('title').textContent=data.label;document.title=data.label+' · Mediabot Network Observatory';
    const latest=data.latest,c=latest?.counts||{},age=latest?Math.max(0,data.now-latest.ts):null;
    $('subtitle').textContent=latest?`${latest.network} · Compteurs réseau /LUSERS · Échantillonnage ${Math.round(latest.interval/60)} min`:'Historique prêt · En attente du premier échantillon IRC';
    const stale=!latest||age>Math.max(900,latest.interval*3);
    $('status').className='status '+(stale?'stale':'fresh');$('status').querySelector('span').textContent=latest?(stale?'Collecte en retard':'Données récentes')+' · '+(age<60?age+' s':Math.floor(age/60)+' min'):'En attente de données';
    $('notice').hidden=!stale;$('notice').textContent=latest?'Le dernier échantillon est ancien. Les valeurs affichées restent celles de la dernière observation ; vérifier la connexion IRC et la publication.':'Aucune donnée reçue pour cette instance. L’historique commencera avec les prochains échantillons.';
    $('cards').replaceChildren();
    for(const key of ['users','channels','operators','servers','visible_users','invisible_users']){
      const card=el('div',undefined,'card');card.style.setProperty('--accent',colors[key]);card.append(el('div',names[key],'card-label'),el('div',value(c[key]),'card-value'));
      const stat=data.summary[key];card.append(el('div',stat?`Min ${value(stat.min)}  /  Max ${value(stat.max)}`:'Pas de valeur sur la période','card-foot'));$('cards').append(card);
    }
    for(const [id,keys]of Object.entries(panels)){const key=keys[0],s=data.summary[key];$(id+'-meta').textContent=s?`Sur la période · min ${value(s.min)} · moyenne ${value(s.mean)} · max ${value(s.max)}`:'Aucune valeur disponible sur cette période';draw(id);}
    $('details').replaceChildren();
    for(const key of ['global_users','users_max','local_users','local_users_max','local_servers','unknown_connections']){const tr=el('tr');tr.append(el('td',names[key]),el('td',value(c[key])));$('details').append(tr);}
    const observed=el('tr');observed.append(el('td','Observation'),el('td',latest?date(latest.ts):'—'));$('details').append(observed);
    $('split').replaceChildren();const sum=c.visible_users+c.invisible_users;
    if(Number.isFinite(sum)&&sum>0){for(const key of ['visible_users','invisible_users']){const s=el('span');s.style.width=c[key]/sum*100+'%';s.title=names[key]+' : '+value(c[key]);$('split').append(s);}}
    $('resolution').textContent=`${value(data.samples)} échantillons sur la période · ${value(data.points.length)} observations affichées · historique 90 jours · heure locale du navigateur. Les courbes longues gardent la dernière valeur réelle de chaque intervalle ; min/max/moyennes utilisent tous les échantillons.`;
    const tbody=$('observations').querySelector('tbody');tbody.replaceChildren();for(const p of data.points){const tr=el('tr');tr.append(el('td',date(p.ts)));for(const key of ['users','visible_users','invisible_users','channels','operators','servers'])tr.append(el('td',value(p.counts[key])));tbody.append(tr);}
    $('networks').replaceChildren();for(const n of data.streams||[]){const a=el('a',n.label);a.href='/'+n.id;if(n.id===stream)a.setAttribute('aria-current','page');$('networks').append(a);}
    $('updated').textContent='Actualisé à '+new Date(data.now*1000).toLocaleTimeString('fr-FR')+' · toutes les 60 s';
  }
  async function refresh(){if(busy)return;busy=true;$('refresh').disabled=true;try{const response=await fetch('/'+encodeURIComponent(stream)+'/data?range='+range,{cache:'no-store',signal:AbortSignal.timeout(10000)});if(!response.ok)throw Error();data=await response.json();render();}catch{ $('notice').hidden=false;$('notice').textContent='Données indisponibles pour le moment. Nouvelle tentative automatique dans une minute.';$('status').className='status stale';$('status').querySelector('span').textContent='Publication indisponible';}finally{busy=false;$('refresh').disabled=false;}}
  for(const button of document.querySelectorAll('[data-range]'))button.addEventListener('click',()=>{if(busy)return;range=button.dataset.range;for(const b of document.querySelectorAll('[data-range]'))b.setAttribute('aria-pressed',String(b===button));refresh();});
  $('refresh').addEventListener('click',refresh);refresh();setInterval(refresh,60000);
})();
