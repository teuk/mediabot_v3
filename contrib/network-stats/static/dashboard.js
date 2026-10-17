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
  function compareMean(current,previous){
    if(!current||!previous||current.n<2||previous.n<2||!finite(current.mean)||!finite(previous.mean))return undefined;
    const delta=current.mean-previous.mean;
    return {delta,percent:previous.mean>0?delta/previous.mean*100:undefined};
  }
  function viewOptions(search){
    const q=new URLSearchParams(search),ranges=['1h','6h','24h','7d','30d','90d'];
    return {range:ranges.includes(q.get('range'))?q.get('range'):'24h',
      end:/^[0-9]{1,12}$/.test(q.get('end')||'')?Number(q.get('end')):null,compare:q.get('compare')==='1'};
  }
  function viewPath(stream,view){
    const q=new URLSearchParams();
    if(view.range!=='24h')q.set('range',view.range);
    if(view.end!==null)q.set('end',String(view.end));
    if(view.compare)q.set('compare','1');
    return '/'+encodeURIComponent(stream)+(q.size?'?'+q:'');
  }
  function nearest(points,ts){
    if(!points.length)return undefined;
    const point=points.reduce((best,p)=>Math.abs(p.ts-ts)<Math.abs(best.ts-ts)?p:best);
    return Math.abs(point.ts-ts)<=point.interval*1.25?point:undefined;
  }
  return Object.freeze({finite,ratio,contiguous,derived,segments,compareMean,viewOptions,viewPath,nearest});
})();
// Explicit language choice only: English is the default, independently of
// browser language. One non-sensitive preference is shared across stream pages.
const NetworkStatsI18n = (() => {
  const messages = {
  "en": {
    "app.title": "Mediabot Network Observatory",
    "brand.subtitle": "NETWORK OBSERVATORY",
    "skip": "Skip to statistics",
    "networks": "Networks",
    "language": "Language",
    "connecting": "Connecting to data…",
    "noscript": "Enable JavaScript to view the charts. Observations remain available through this network’s JSON data URL.",
    "eyebrow": "IRC / NETWORK OBSERVATORY",
    "heading": "Network statistics",
    "subtitle": "Network activity, observed over time.",
    "period": "Time range",
    "range.1h": "1 h",
    "range.6h": "6 h",
    "range.24h": "24 h",
    "range.7d": "7 d",
    "range.30d": "30 d",
    "range.90d": "90 d",
    "refresh.aria": "Refresh data",
    "refresh.title": "Refresh",
    "cards.aria": "Latest sample and change over the selected range",
    "telemetry.aria": "Collection quality",
    "trends": "TRENDS",
    "charts.heading": "The network in charts",
    "zero": "Start axes at zero",
    "reset": "Reset zoom",
    "export": "Export CSV",
    "interaction": "Hover to inspect an observation · Drag within a chart to zoom · Click a legend to hide a series · Axes adapt to the values.",
    "charts.aria": "Counter trends",
    "counters.eyebrow": "ALL COUNTERS",
    "counters.heading": "The measurements in detail",
    "counters.intro": "Latest snapshot and statistics calculated from every sample in the selected range.",
    "counters.badge": "12 COUNTERS / LUSERS",
    "counters.caption": "Twelve aggregate counters; missing values are shown as a dash",
    "table.counter": "Counter",
    "table.latest": "Latest",
    "table.delta": "Δ range",
    "table.min": "Minimum",
    "table.mean": "Mean",
    "table.max": "Maximum",
    "table.median": "Median",
    "table.p95": "P95",
    "table.stddev": "Std. deviation",
    "table.samples": "Samples",
    "method.heading": "Observations, without extrapolation",
    "method.scope": "Aggregate /LUSERS counters, exactly as reported by the server. “Invisible” refers to IRC user mode; “operator” means a network operator, not a channel operator. No identities or conversations are collected.",
    "method.totals": "The 251 total and the global 266 total retain their separate scopes. Server-reported peaks are different from the maxima observed here. Ratios use only counters present in the same sample; they measure neither unique audience nor actual average channel size.",
    "method.gaps": "Net change does not count individual connections and disconnections. Coverage estimates measured time slots, never network uptime. Gaps and unknown values remain visible; no curve is extended artificially.",
    "method.retention": "History: 90 days. Times use your browser’s local time zone.",
    "method.summary": "Calculation method and accessible observations",
    "method.details": "Δ = last minus first known value in the selected range. Mean, median, P95 (nearest rank) and population standard deviation use observations without time weighting. Cards and the summary table keep the full range when a chart is zoomed. A collection gap is more than 2.5 sample intervals between observations; range boundaries are not counted as gaps.",
    "observations.caption": "Displayed observations; CSV contains the selected period only (UTC timestamps)",
    "updated.initial": "Automatic refresh every 60 seconds",
    "chart.users.title": "Network population",
    "chart.users.subtitle": "Visible, invisible and total users; reported peaks are available in the legend.",
    "chart.channels.title": "Formed channels",
    "chart.channels.subtitle": "Channels reported by the network, without their names.",
    "chart.net.title": "Population dynamics",
    "chart.net.subtitle": "Net change normalised per hour, between nearby observations.",
    "chart.visibility.title": "User visibility",
    "chart.visibility.subtitle": "Shares calculated from the sum of visible and invisible users.",
    "chart.operators.title": "IRC operators",
    "chart.operators.subtitle": "Network operators, distinct from channel operators.",
    "chart.servers.title": "Reported topology",
    "chart.servers.subtitle": "Network servers and links of the connected IRC server.",
    "chart.local.title": "Clients of the connected server",
    "chart.local.subtitle": "Local counters; the server’s peak remains a separate series.",
    "chart.unknown.title": "Unknown connections",
    "chart.unknown.subtitle": "An explicitly reported value; an absent counter remains unknown.",
    "chart.density.title": "Users per server",
    "chart.density.subtitle": "Ratio of the retained user total to the reported server count.",
    "chart.channels-ratio.title": "Users / channels ratio",
    "chart.channels-ratio.subtitle": "A network-wide indicator, not the actual average channel size.",
    "chart.operator-ratio.title": "Operator presence",
    "chart.operator-ratio.subtitle": "Number of IRC operators per 1,000 users.",
    "metric.users": "Users",
    "metric.visible_users": "Visible",
    "metric.invisible_users": "Invisible",
    "metric.channels": "Formed channels",
    "metric.operators": "IRC operators",
    "metric.servers": "Network servers",
    "metric.unknown_connections": "Unknown connections",
    "metric.local_users": "Local clients",
    "metric.local_users_max": "Reported local peak (265)",
    "metric.local_servers": "Local server links",
    "metric.global_users": "Global total (266)",
    "metric.users_max": "Reported global peak (266)",
    "metric.net_rate": "Net change / hour",
    "metric.invisible_pct": "Invisible %",
    "metric.visible_pct": "Visible %",
    "metric.users_per_channel": "Users / channel",
    "metric.users_per_server": "Users / server",
    "metric.operators_per_1000": "Operators / 1,000 users",
    "metric.local_pct": "Local share %",
    "badge.calculated": "CALCULATED",
    "badge.ratio": "RATIO",
    "chart.accessible": "{title}; use arrow keys to browse observations and Escape to reset zoom. An accessible table is available below.",
    "empty.waiting": "Waiting for the first observations",
    "empty.counter": "Counter not supplied in this range",
    "empty.hidden": "Series hidden in the legend",
    "empty.primary": "Primary series absent in this range",
    "meta.min": "MIN",
    "meta.mean": "AVG",
    "meta.max": "MAX",
    "meta.zoom": "ZOOM",
    "meta.calculated": "CALCULATED",
    "subtitle.live": "{network} · /LUSERS every {minutes} min · Browser local time",
    "subtitle.empty": "History ready · Waiting for the first IRC sample",
    "status.stale": "Collection delayed",
    "status.fresh": "Recent data",
    "status.empty": "Waiting for data",
    "notice.stale": "Collection is delayed. Values remain those of the last observation; check the IRC connection and publication.",
    "notice.empty": "No data received for this instance. History will start with the next samples.",
    "card.delta": "{delta} over the range{percent}",
    "card.empty": "No measurements in this range",
    "telemetry.samples": "Samples",
    "telemetry.coverage": "Measured coverage",
    "telemetry.gaps": "Gaps between samples",
    "telemetry.latest": "Latest observation",
    "counter.dates": "First: {first} · Last: {last} · Peak: {peak}",
    "observation": "Observation",
    "resolution": "{samples} raw samples · {points} displayed observations · display interval {interval} · 90-day retention. Long-range charts retain the last actual observation in each interval; statistics use every sample. Longest internal gap: {gap}.",
    "updated": "Updated at {time} · {zone} · 60 s",
    "notice.unavailable": "Data is temporarily unavailable. The last displayed values are retained; another attempt will run automatically in one minute.",
    "status.unavailable": "Publication unavailable",
    "preview.banner": "DESIGN PREVIEW · Entirely simulated data · No real history and no connection to IRC instances",
    "window.aria": "History navigation and sharing",
    "window.earlier": "Earlier",
    "window.later": "Later",
    "window.live": "Live",
    "window.liveBadge": "LIVE",
    "window.historyBadge": "HISTORY",
    "window.share": "Copy view link",
    "window.copied": "View link copied.",
    "window.copyFallback": "Copy this period link: {link}",
    "window.dates": "{from} → {to}",
    "comparison.toggle": "Compare previous period",
    "comparison.key": "Previous period",
    "comparison.loading": "Previous-period comparison is not available in the last received data.",
    "comparison.info": "Previous: {from} → {to} · {samples} samples · {coverage}% coverage. Dashed curves are shifted by one equal-length period; both periods retain their collection gaps.",
    "comparison.empty": "No previous-period observations are available. No baseline or change is inferred.",
    "comparison.mean": "Previous mean",
    "comparison.delta": "Δ mean vs previous",
    "comparison.percent": "Δ mean %",
    "comparison.card": "Mean vs previous: {delta}{percent}",
    "comparison.cardEmpty": "More observations needed for comparison",
    "comparison.sample": "Previous sample · {time}",
    "comparison.noSample": "Previous sample unavailable here",
    "card.extrema": "Low {low} · Peak {high}",
    "card.extremaDates": "Low at {low} · Peak at {high}",
    "meta.extrema": "LOW {low} · PEAK {high}",
    "status.historical": "Historical window",
    "notice.historicalEmpty": "No observations in this historical window. Choose a later period or return to Live.",
    "notice.historicalGap": "This historical window ends without a recent observation. Gaps are retained; this is not a current network-status report.",
    "notice.expired": "This historical endpoint is outside the retained history or in the future. Return to Live to choose another view.",
    "method.comparison": "History uses fixed elapsed durations, with at most 90 days retained. The previous period ends strictly before the selected period starts: no observation is counted twice. Comparison columns use sample means and require at least two observations for that counter in each period; unequal collection coverage can affect the result. A zero previous mean has no percentage change. Dashed curves align elapsed offsets, not local calendar hours across daylight-saving changes. CSV exports contain only the selected period.",
    "comparison.selected": "Selected period",
    "table.period": "Period"
  },
  "fr": {
    "app.title": "Observatoire réseau Mediabot",
    "brand.subtitle": "OBSERVATOIRE RÉSEAU",
    "skip": "Aller aux statistiques",
    "networks": "Réseaux",
    "language": "Langue",
    "connecting": "Connexion aux données…",
    "noscript": "Activez JavaScript pour afficher les graphiques. Les observations restent accessibles via l’URL de données JSON de ce réseau.",
    "eyebrow": "IRC / OBSERVATOIRE RÉSEAU",
    "heading": "Statistiques réseau",
    "subtitle": "L’activité du réseau, observée dans la durée.",
    "period": "Période",
    "range.1h": "1 h",
    "range.6h": "6 h",
    "range.24h": "24 h",
    "range.7d": "7 j",
    "range.30d": "30 j",
    "range.90d": "90 j",
    "refresh.aria": "Actualiser les données",
    "refresh.title": "Actualiser",
    "cards.aria": "Dernier échantillon et variation sur la période",
    "telemetry.aria": "Qualité de collecte",
    "trends": "TENDANCES",
    "charts.heading": "Le réseau en courbes",
    "zero": "Axes à partir de zéro",
    "reset": "Réinitialiser le zoom",
    "export": "Exporter CSV",
    "interaction": "Survolez pour lire une observation · Glissez dans une courbe pour zoomer · Cliquez une légende pour masquer une série · Les axes s’adaptent aux valeurs.",
    "charts.aria": "Évolution des compteurs",
    "counters.eyebrow": "TOUS LES COMPTEURS",
    "counters.heading": "La mesure, en détail",
    "counters.intro": "Dernier instantané et statistiques calculées sur tous les échantillons de la période choisie.",
    "counters.badge": "12 COMPTEURS / LUSERS",
    "counters.caption": "Les douze compteurs agrégés, valeurs absentes signalées par un tiret",
    "table.counter": "Compteur",
    "table.latest": "Dernier",
    "table.delta": "Δ période",
    "table.min": "Minimum",
    "table.mean": "Moyenne",
    "table.max": "Maximum",
    "table.median": "Médiane",
    "table.p95": "P95",
    "table.stddev": "Écart-type",
    "table.samples": "Mesures",
    "method.heading": "Des observations, sans extrapolation",
    "method.scope": "Compteurs agrégés de /LUSERS, tels que le serveur les annonce. « Invisible » désigne le mode utilisateur IRC ; « opérateur » désigne un opérateur du réseau, pas d’un canal. Aucune identité ni conversation n’est collectée.",
    "method.totals": "Le total 251 et le total global 266 gardent leurs portées distinctes. Les pics annoncés par le serveur ne sont pas les maxima observés ici. Les ratios utilisent uniquement des compteurs présents dans un même échantillon ; ils ne mesurent ni une audience unique ni la taille moyenne réelle des canaux.",
    "method.gaps": "La variation nette ne compte pas les connexions et déconnexions individuellement. La couverture estime les créneaux mesurés, jamais la disponibilité du réseau. Les lacunes et valeurs inconnues restent visibles ; aucune courbe n’est prolongée artificiellement.",
    "method.retention": "Historique : 90 jours. Affichage en heure locale du navigateur.",
    "method.summary": "Méthode de calcul et observations accessibles",
    "method.details": "Δ = dernière moins première valeur connue de la période. Moyenne, médiane, P95 (rang supérieur) et écart-type de population portent sur les observations, sans pondération temporelle. Les cartes et le tableau gardent la période complète quand une courbe est zoomée. Un trou de collecte correspond à plus de 2,5 fois la cadence entre deux observations ; les bords de période ne sont pas comptés comme des trous.",
    "observations.caption": "Observations affichées ; le CSV contient uniquement la période sélectionnée (horodatages UTC)",
    "updated.initial": "Actualisation automatique toutes les 60 secondes",
    "chart.users.title": "Population du réseau",
    "chart.users.subtitle": "Visibles, invisibles et total ; pics annoncés disponibles dans la légende.",
    "chart.channels.title": "Canaux formés",
    "chart.channels.subtitle": "Canaux annoncés par le réseau, sans leurs noms.",
    "chart.net.title": "Dynamique de population",
    "chart.net.subtitle": "Variation nette normalisée par heure, entre observations proches.",
    "chart.visibility.title": "Répartition des utilisateurs",
    "chart.visibility.subtitle": "Proportions calculées sur la somme visible + invisible.",
    "chart.operators.title": "Opérateurs IRC",
    "chart.operators.subtitle": "Les opérateurs du réseau, distincts des opérateurs de canaux.",
    "chart.servers.title": "Topologie annoncée",
    "chart.servers.subtitle": "Serveurs du réseau et liens du serveur de connexion.",
    "chart.local.title": "Clients du serveur de connexion",
    "chart.local.subtitle": "Compteurs locaux ; le pic serveur reste une série distincte.",
    "chart.unknown.title": "Connexions inconnues",
    "chart.unknown.subtitle": "Valeur explicitement annoncée ; une absence reste inconnue.",
    "chart.density.title": "Utilisateurs par serveur",
    "chart.density.subtitle": "Rapport du total retenu au nombre de serveurs annoncé.",
    "chart.channels-ratio.title": "Rapport utilisateurs / canaux",
    "chart.channels-ratio.subtitle": "Indicateur global, pas une taille moyenne réelle de canal.",
    "chart.operator-ratio.title": "Présence des opérateurs",
    "chart.operator-ratio.subtitle": "Nombre d’opérateurs IRC pour 1 000 utilisateurs.",
    "metric.users": "Utilisateurs",
    "metric.visible_users": "Visibles",
    "metric.invisible_users": "Invisibles",
    "metric.channels": "Canaux formés",
    "metric.operators": "Opérateurs IRC",
    "metric.servers": "Serveurs du réseau",
    "metric.unknown_connections": "Connexions inconnues",
    "metric.local_users": "Clients locaux",
    "metric.local_users_max": "Pic local annoncé (265)",
    "metric.local_servers": "Liens serveurs locaux",
    "metric.global_users": "Total global (266)",
    "metric.users_max": "Pic global annoncé (266)",
    "metric.net_rate": "Variation nette / heure",
    "metric.invisible_pct": "Invisibles %",
    "metric.visible_pct": "Visibles %",
    "metric.users_per_channel": "Utilisateurs / canal",
    "metric.users_per_server": "Utilisateurs / serveur",
    "metric.operators_per_1000": "Opérateurs / 1 000 utilisateurs",
    "metric.local_pct": "Part locale %",
    "badge.calculated": "CALCULÉ",
    "badge.ratio": "RATIO",
    "chart.accessible": "{title} ; flèches pour parcourir les observations, Échap pour annuler le zoom. Tableau accessible en bas de page.",
    "empty.waiting": "En attente des premières observations",
    "empty.counter": "Compteur non fourni sur cette période",
    "empty.hidden": "Séries masquées dans la légende",
    "empty.primary": "Série principale absente sur cette période",
    "meta.min": "MIN",
    "meta.mean": "MOY",
    "meta.max": "MAX",
    "meta.zoom": "ZOOM",
    "meta.calculated": "CALCULÉ",
    "subtitle.live": "{network} · /LUSERS toutes les {minutes} min · Horaires du navigateur",
    "subtitle.empty": "Historique prêt · En attente du premier échantillon IRC",
    "status.stale": "Collecte en retard",
    "status.fresh": "Données récentes",
    "status.empty": "En attente de données",
    "notice.stale": "La collecte est en retard. Les valeurs restent celles de la dernière observation ; vérifier la connexion IRC et la publication.",
    "notice.empty": "Aucune donnée reçue pour cette instance. L’historique commencera avec les prochains échantillons.",
    "card.delta": "{delta} sur la période{percent}",
    "card.empty": "Aucune mesure sur la période",
    "telemetry.samples": "Échantillons",
    "telemetry.coverage": "Couverture mesurée",
    "telemetry.gaps": "Trous entre mesures",
    "telemetry.latest": "Dernière observation",
    "counter.dates": "Première : {first} · Dernière : {last} · Pic : {peak}",
    "observation": "Observation",
    "resolution": "{samples} mesures brutes · {points} observations affichées · intervalle d’affichage {interval} · conservation 90 jours. Les courbes longues gardent la dernière observation réelle de chaque intervalle ; les statistiques utilisent toutes les mesures. Plus grand trou intérieur : {gap}.",
    "updated": "Actualisé à {time} · {zone} · 60 s",
    "notice.unavailable": "Données indisponibles pour le moment. Les dernières valeurs affichées sont conservées ; nouvelle tentative automatique dans une minute.",
    "status.unavailable": "Publication indisponible",
    "preview.banner": "APERÇU DU DESIGN · Données entièrement simulées · Aucun historique réel, aucune connexion aux instances IRC",
    "window.aria": "Navigation dans l’historique et partage",
    "window.earlier": "Précédent",
    "window.later": "Suivant",
    "window.live": "Direct",
    "window.liveBadge": "DIRECT",
    "window.historyBadge": "HISTORIQUE",
    "window.share": "Copier le lien de cette vue",
    "window.copied": "Lien de la vue copié.",
    "window.copyFallback": "Copiez ce lien de période : {link}",
    "window.dates": "{from} → {to}",
    "comparison.toggle": "Comparer à la période précédente",
    "comparison.key": "Période précédente",
    "comparison.loading": "La comparaison avec la période précédente n’est pas disponible dans les dernières données reçues.",
    "comparison.info": "Précédente : {from} → {to} · {samples} mesures · couverture {coverage} %. Les courbes en pointillés sont décalées d’une période de même durée ; les trous de collecte restent visibles.",
    "comparison.empty": "Aucune observation disponible pour la période précédente. Aucune référence ni évolution n’est déduite.",
    "comparison.mean": "Moyenne précédente",
    "comparison.delta": "Δ moyenne / précédente",
    "comparison.percent": "Δ moyenne %",
    "comparison.card": "Moyenne / précédente : {delta}{percent}",
    "comparison.cardEmpty": "Comparaison : mesures insuffisantes",
    "comparison.sample": "Mesure précédente · {time}",
    "comparison.noSample": "Aucune mesure précédente ici",
    "card.extrema": "Minimum {low} · Pic {high}",
    "card.extremaDates": "Minimum le {low} · Pic le {high}",
    "meta.extrema": "MIN LE {low} · PIC LE {high}",
    "status.historical": "Période historique",
    "notice.historicalEmpty": "Aucune observation sur cette période historique. Choisissez une période suivante ou revenez au direct.",
    "notice.historicalGap": "Cette période historique se termine sans observation récente. Les trous sont conservés ; cela ne décrit pas l’état actuel du réseau.",
    "notice.expired": "La fin de cette période est hors de l’historique conservé ou dans le futur. Revenez au direct pour choisir une autre vue.",
    "method.comparison": "L’historique utilise des durées écoulées fixes, avec au plus 90 jours conservés. La période précédente exclut l’instant de début de la période sélectionnée : aucune observation n’est comptée deux fois. Les colonnes de comparaison utilisent les moyennes des mesures et exigent au moins deux observations du compteur dans chaque période ; une couverture inégale peut influencer le résultat. Une moyenne précédente nulle ne donne pas de variation en pourcentage. Les pointillés alignent les durées écoulées, pas les heures locales à travers un changement d’heure. Le CSV contient uniquement la période sélectionnée.",
    "comparison.selected": "Période sélectionnée",
    "table.period": "Période"
  }
};
  for(const table of Object.values(messages)) Object.freeze(table);
  Object.freeze(messages);
  const storageKey='mediabot.networkStats.language';
  const select=language=>language==='fr'?'fr':'en';
  const locale=language=>select(language)==='fr'?'fr-FR':'en-GB';
  function read(storage){try{return select(storage.getItem(storageKey));}catch{return 'en';}}
  function save(storage,language){try{storage.setItem(storageKey,select(language));return true;}catch{return false;}}
  function text(language,key,values={}) {
    const template=messages[select(language)][key]??messages.en[key]??key;
    return template.replace(/\{([A-Za-z_]+)\}/g,(_,name)=>String(values[name]??''));
  }
  return Object.freeze({messages,storageKey,select,locale,read,save,text});
})();
if(typeof module!=='undefined'&&module.exports) module.exports=Object.freeze({...NetworkStatsMath,i18n:NetworkStatsI18n});
else (() => {
  const $=id=>document.getElementById(id), M=NetworkStatsMath;
  const stream=location.pathname.split('/').filter(Boolean)[0];
  const I=NetworkStatsI18n;
  let language='en';
  try{language=I.read(window.localStorage);}catch{}
  let locale=I.locale(language),nf=new Intl.NumberFormat(locale,{maximumFractionDigits:2});
  const t=(key,values)=>I.text(language,key,values);
  const names=key=>t('metric.'+key);
  const value=n=>M.finite(n)?nf.format(n):'—';
  const signed=n=>M.finite(n)?(n>0?'+':'')+value(n):'—';
  const date=ts=>M.finite(ts)?new Date(ts*1000).toLocaleString(locale):'—';
  const duration=n=>n>=3600?value(n/3600)+' h':n>=60?value(n/60)+' min':value(n)+' s';
  const rawKeys=['users','visible_users','invisible_users','channels','operators','servers','global_users','users_max','local_users','local_users_max','local_servers','unknown_connections'];
  const colors={users:'#74bfb4',visible_users:'#86a9dc',invisible_users:'#ae9ccf',channels:'#86a9dc',operators:'#c8ae7b',servers:'#9aaacc',unknown_connections:'#c4909e',local_users:'#74bfb4',local_users_max:'#8f999d',local_servers:'#bdac89',global_users:'#adb6c0',users_max:'#bcaa81',net_rate:'#83bca7',invisible_pct:'#ae9ccf',visible_pct:'#86a9dc',users_per_channel:'#89afb8',users_per_server:'#9aaacc',operators_per_1000:'#c8ae7b',local_pct:'#74bfb4'};
  const configs=[
    ['users','chart.users.title','chart.users.subtitle',['users','visible_users','invisible_users','global_users','users_max'],'251 / 266','',true],
    ['channels','chart.channels.title','chart.channels.subtitle',['channels'],'254',''],
    ['net','chart.net.title','chart.net.subtitle',['net_rate'],'calculated','/ h'],
    ['visibility','chart.visibility.title','chart.visibility.subtitle',['invisible_pct','visible_pct'],'251','%'],
    ['operators','chart.operators.title','chart.operators.subtitle',['operators'],'252',''],
    ['servers','chart.servers.title','chart.servers.subtitle',['servers','local_servers'],'251 / 255',''],
    ['local','chart.local.title','chart.local.subtitle',['local_users','local_users_max'],'255 / 265',''],
    ['unknown','chart.unknown.title','chart.unknown.subtitle',['unknown_connections'],'253',''],
    ['density','chart.density.title','chart.density.subtitle',['users_per_server'],'ratio',''],
    ['channels-ratio','chart.channels-ratio.title','chart.channels-ratio.subtitle',['users_per_channel'],'ratio',''],
    ['operator-ratio','chart.operator-ratio.title','chart.operator-ratio.subtitle',['operators_per_1000'],'ratio','']
  ];
  const panels=new Map(),disabled=new Set(['global_users','users_max','local_users_max']);
  const initial=M.viewOptions(location.search);
  let range=initial.range,until=initial.end,compare=initial.compare;
  let data=null,points=[],previousPoints=[],busy=false,unavailable=false,expired=false,zoom=null,cursor=null,drag=null,raf=0;
  const currentView=()=>({range,end:until,compare});
  function updateURL(){try{history.replaceState(null,'',M.viewPath(stream,currentView()));}catch{}}

  const el=(tag,text,cls)=>{const x=document.createElement(tag);if(text!==undefined)x.textContent=text;if(cls)x.className=cls;return x;};
  function visible(){return zoom?points.filter(p=>p.ts>=zoom[0]&&p.ts<=zoom[1]):points;}
  const bounds=()=>zoom||[data?.from||0,data?.now||1];
  function allDraw(){for(const id of panels.keys())draw(id);}
  function schedule(){if(!raf)raf=requestAnimationFrame(()=>{raf=0;allDraw();});}
  function resetZoom(){zoom=null;drag=null;$('reset-zoom').hidden=true;schedule();}
  for(const [id,title,subtitle,keys,badge,unit,wide] of configs){
    const article=el('article',undefined,'panel'+(wide?' wide':'')),head=el('div',undefined,'panel-heading'),intro=el('div');
    const heading=el('h2'),description=el('p'),badgeNode=el('span',undefined,'badge');
    intro.append(heading,description);head.append(intro,badgeNode);
    const legend=el('div',undefined,'legend'),plot=el('div',undefined,'plot'),canvas=el('canvas'),tip=el('div',undefined,'tooltip'),meta=el('p',undefined,'chart-meta');
    canvas.id=id;canvas.tabIndex=0;canvas.setAttribute('role','img');
    tip.hidden=true;plot.append(canvas,tip);article.append(head,legend,plot,meta);$('charts').append(article);
    const comparisonKey=el('span',undefined,'comparison-key');comparisonKey.hidden=true;legend.append(comparisonKey);
    panels.set(id,{canvas,tip,keys,unit,meta,heading,description,badgeNode,title,subtitle,badge,comparisonKey,buttons:new Map()});
    for(const key of keys){const b=el('button',names(key));b.style.setProperty('--accent',colors[key]);b.setAttribute('aria-pressed',String(!disabled.has(key)));b.addEventListener('click',()=>{disabled.has(key)?disabled.delete(key):disabled.add(key);b.setAttribute('aria-pressed',String(!disabled.has(key)));draw(id);});legend.append(b);panels.get(id).buttons.set(key,b);}
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
    const {tip,keys,canvas,unit}=panels.get(id),ps=visible();if(!ps.length&&(!compare||!previousPoints.length))return;
    const p=ps.length?ps.reduce((best,x)=>Math.abs(x.ts-cursor)<Math.abs(best.ts-cursor)?x:best):null;
    tip.replaceChildren(el('strong',p?date(p.ts):t('card.empty')));
    for(const key of keys)if(!disabled.has(key)){const row=el('div');row.append(el('span',names(key)),el('b',value(p?.counts[key])+(M.finite(p?.counts[key])&&unit?' '+unit:'')));tip.append(row);}
    if(compare){
      const shift=data.now-data.from,prior=M.nearest(previousPoints,cursor-shift);
      tip.append(el('strong',prior?t('comparison.sample',{time:date(prior.ts)}):t('comparison.noSample'),'comparison-tip'));
      if(prior)for(const key of keys)if(!disabled.has(key)){const row=el('div');row.append(el('span',names(key)),el('b',value(prior.counts[key])+(M.finite(prior.counts[key])&&unit?' '+unit:'')));tip.append(row);}
    }
    tip.hidden=false;tip.style.left=Math.max(3,Math.min(canvas.clientWidth-tip.offsetWidth-3,left+12))+'px';tip.style.top='12px';
  }
  function draw(id){
    const {canvas,keys:allKeys,unit,meta}=panels.get(id),r=canvas.getBoundingClientRect(),dpr=Math.min(window.devicePixelRatio||1,3);
    canvas.width=Math.round(r.width*dpr);canvas.height=Math.round(r.height*dpr);const c=canvas.getContext('2d');c.scale(dpr,dpr);
    const w=r.width,h=r.height,L=58,R=14,T=17,B=31,[from,to]=bounds(),ps=visible(),keys=allKeys.filter(k=>!disabled.has(k));
    c.font='10px system-ui';c.fillStyle='#8699b0';if(!data)return;
    const shift=data.now-data.from;
    const prior=compare?previousPoints.map(p=>({...p,ts:p.ts+shift})).filter(p=>p.ts>=from&&p.ts<=to):[];
    const primary=keys[0],rawStat=!zoom?data.summary[primary]:null;
    const marks=rawStat?[{ts:rawStat.min_at,value:rawStat.min},{ts:rawStat.max_at,value:rawStat.max}]:[];
    const vals=[...ps,...prior].flatMap(p=>keys.map(k=>p.counts[k]).filter(M.finite));
    vals.push(...marks.filter(p=>p.ts>=from&&p.ts<=to).map(p=>p.value));
    if(!vals.length){c.textAlign='center';c.fillText(!data.samples?t('empty.waiting'):keys.length?t('empty.counter'):t('empty.hidden'),w/2,h/2);meta.textContent='—';return;}
    const top=Math.max(...vals),bottom=Math.min(...vals),pad=Math.max(unit==='%'?1:.1,(top-bottom)*.13);
    let low=bottom<0?bottom-pad:Math.max(0,bottom-pad),high=Math.max(low+1,top+pad);
    if($('zero').checked){low=Math.min(0,low);high=Math.max(0,high);}if(unit==='%'){low=Math.max(0,low);high=Math.min(100,high);if(high<=low)high=low+1;}
    const x=t=>L+(t-from)/(to-from)*(w-L-R),y=v=>h-B-(v-low)/(high-low)*(h-T-B);
    c.strokeStyle='#263448';c.lineWidth=.7;c.textAlign='right';
    for(let i=0;i<=4;i++){const v=low+(high-low)*i/4,yy=y(v);c.beginPath();c.moveTo(L,yy);c.lineTo(w-R,yy);c.stroke();const label=Math.abs(v)>=10000?nf.format(v/1000)+'k':nf.format(Math.round(v*10)/10);c.fillText(label,L-8,yy+3);}
    c.textAlign='center';for(let i=0;i<=4;i++){const t=from+(to-from)*i/4,dt=new Date(t*1000);const label=to-from>86400?dt.toLocaleDateString(locale,{day:'2-digit',month:'2-digit'}):dt.toLocaleTimeString(locale,{hour:'2-digit',minute:'2-digit'});c.fillText(label,Math.max(25,Math.min(w-25,x(t))),h-7);}
    if(low<0&&high>0){c.strokeStyle='#6b7b8d';c.beginPath();c.moveTo(L,y(0));c.lineTo(w-R,y(0));c.stroke();}
    c.save();c.beginPath();c.rect(L,T,w-L-R,h-T-B);c.clip();
    if(prior.length){c.save();c.globalAlpha=.45;c.setLineDash([4,5]);c.lineWidth=1.2;
      for(const key of keys){c.strokeStyle=colors[key];for(const part of M.segments(prior,key,data.comparison.bucket_seconds)){
        c.beginPath();part.forEach((p,i)=>i?c.lineTo(x(p.ts),y(p.counts[key])):c.moveTo(x(p.ts),y(p.counts[key])));c.stroke();
      }}c.restore();}
    for(const key of keys){const col=colors[key],dashed=key.endsWith('_max')||key==='global_users';c.strokeStyle=col;c.lineWidth=key==='users'?2.1:1.6;c.setLineDash(dashed?[5,4]:[]);
      for(const segment of M.segments(ps,key,data.bucket_seconds)){
        c.beginPath();segment.forEach((p,i)=>i?c.lineTo(x(p.ts),y(p.counts[key])):c.moveTo(x(p.ts),y(p.counts[key])));c.stroke();
        if(!dashed&&segment.length>1){const gradient=c.createLinearGradient(0,T,0,h-B);gradient.addColorStop(0,col+'20');gradient.addColorStop(1,col+'02');c.lineTo(x(segment.at(-1).ts),h-B);c.lineTo(x(segment[0].ts),h-B);c.closePath();c.fillStyle=gradient;c.fill();}
        c.fillStyle=col;for(const p of segment)if(segment.length<4){c.beginPath();c.arc(x(p.ts),y(p.counts[key]),2.5,0,Math.PI*2);c.fill();}
      }
    }c.setLineDash([]);
    for(const mark of marks)if(mark.ts>=from&&mark.ts<=to){c.fillStyle='#111925';c.strokeStyle=colors[primary];c.lineWidth=1.4;c.beginPath();c.arc(x(mark.ts),y(mark.value),3.2,0,Math.PI*2);c.fill();c.stroke();}
    if(cursor!==null&&cursor>=from&&cursor<=to){c.strokeStyle='#a8b6ca66';c.beginPath();c.moveTo(x(cursor),T);c.lineTo(x(cursor),h-B);c.stroke();}
    if(drag?.id===id){c.fillStyle='#90b4d522';c.fillRect(x(drag.start),T,x(drag.end)-x(drag.start),h-T-B);}c.restore();
    const key=keys[0],s=!zoom?data.summary[key]:null,vs=ps.map(p=>p.counts[key]).filter(M.finite);
    meta.replaceChildren();if(s)meta.append(t('meta.min')+' ',el('b',value(s.min)),'   '+t('meta.mean')+' ',el('b',value(s.mean)),'   '+t('meta.max')+' ',el('b',value(s.max)),'   Δ ',el('b',signed(s.delta)));
    else if(vs.length)meta.append(t(zoom?'meta.zoom':'meta.calculated')+' · ',t('meta.min')+' ',el('b',value(Math.min(...vs))),'   '+t('meta.max')+' ',el('b',value(Math.max(...vs))),unit?' '+unit:'');
    else meta.textContent=t('empty.primary');
    if(s)meta.append(el('span',' · '+t('meta.extrema',{low:date(s.min_at),high:date(s.max_at)}),'extrema-dates'));
  }
  function spark(canvas,key){
    const c=canvas.getContext('2d'),w=180,h=78;canvas.width=w;canvas.height=h;
    const vals=points.map(p=>p.counts[key]).filter(M.finite);if(!vals.length)return;
    const min=Math.min(...vals),max=Math.max(...vals),span=Math.max(1,max-min),x=t=>3+(t-data.from)/(data.now-data.from)*(w-6),y=v=>h-4-(v-min)/span*(h-8);
    c.strokeStyle=colors[key];c.lineWidth=2;c.beginPath();for(const part of M.segments(points,key,data.bucket_seconds)){part.forEach((p,i)=>i?c.lineTo(x(p.ts),y(p.counts[key])):c.moveTo(x(p.ts),y(p.counts[key])));}c.stroke();
  }
  function render(){
    const latest=data.latest,c=(data.live===false&&!data.samples)?{}:latest?.counts||{},age=latest?Math.max(0,data.now-latest.ts):null,stale=!latest||age>Math.max(900,latest.interval*3);
    const comparison=compare?data.comparison:null;
    previousPoints=(comparison?.points||[]).map((p,i)=>({...p,counts:M.derived(p,i?comparison.points[i-1]:null)}));
    $('window-dates').textContent=t('window.dates',{from:date(data.from),to:date(data.now)});
    $('window-mode').textContent=t(data.live===false?'window.historyBadge':'window.liveBadge');
    $('window-mode').className='window-mode'+(data.live===false?'':' live');
    $('earlier').disabled=busy||data.from<=data.retention_from;
    $('later').disabled=busy||until===null;$('live').disabled=busy||until===null;
    $('comparison-info').hidden=!compare;
    $('comparison-info').textContent=!comparison?t('comparison.loading'):comparison.samples?t('comparison.info',{from:date(comparison.from),to:date(comparison.now),samples:value(comparison.samples),coverage:value(comparison.quality.coverage_percent)}):t('comparison.empty');
    for(const panel of panels.values()){panel.comparisonKey.hidden=!compare;panel.comparisonKey.textContent=t('comparison.key');}
    for(const node of document.querySelectorAll('.comparison-col'))node.hidden=!compare;
    points=data.points.map((p,i)=>({...p,counts:M.derived(p,i?data.points[i-1]:null)}));
    $('title').textContent=data.label;document.title=data.label+' · '+t('app.title');
    $('subtitle').textContent=latest?t('subtitle.live',{network:latest.network,minutes:value(latest.interval/60)}):t('subtitle.empty');
    $('status').className='status '+(stale?'stale':'fresh');$('status').querySelector('span').textContent=latest?t(data.live===false?'status.historical':stale?'status.stale':'status.fresh')+' · '+duration(age):t('status.empty');
    $('notice').hidden=!stale;$('notice').textContent=t(data.live===false?(data.samples?'notice.historicalGap':'notice.historicalEmpty'):latest?'notice.stale':'notice.empty');
    $('cards').replaceChildren();
    for(const [idx,key] of ['users','channels','operators','servers'].entries()){
      const card=el('article',undefined,'card'),head=el('div',undefined,'card-top'),cv=el('canvas',undefined,'card-spark'),s=data.summary[key];card.style.setProperty('--accent',colors[key]);
      cv.setAttribute('aria-hidden','true');head.append(el('span',names(key),'card-label'),el('span','0'+(idx+1),'card-index'));card.append(head,el('div',value(c[key]),'card-value'),cv);
      card.append(el('div',s?t('card.delta',{delta:signed(s.delta),percent:M.finite(s.delta_percent)?' · '+signed(s.delta_percent)+' %':''}):t('card.empty'),'card-foot'));if(s){const limits=el('div',t('card.extrema',{low:value(s.min),high:value(s.max)}),'card-range');limits.title=t('card.extremaDates',{low:date(s.min_at),high:date(s.max_at)});card.append(limits);}
      if(compare){const d=M.compareMean(s,comparison?.summary[key]);card.append(el('div',d?t('comparison.card',{delta:signed(d.delta),percent:M.finite(d.percent)?' · '+signed(d.percent)+' %':''}):t('comparison.cardEmpty'),'card-comparison'));}
      $('cards').append(card);spark(cv,key);
    }
    const q=data.quality||{};$('telemetry').replaceChildren();
    for(const [label,text] of [[t('telemetry.samples'),value(data.samples)],[t('telemetry.coverage'),value(q.coverage_percent)+' %'],[t('telemetry.gaps'),value(q.gaps)],[t('telemetry.latest'),latest?new Date(latest.ts*1000).toLocaleTimeString(locale):'—']]){const block=el('div');block.append(el('small',label),el('b',text));$('telemetry').append(block);}
    $('details').replaceChildren();
    for(const key of rawKeys){const s=data.summary[key],tr=el('tr'),label=el('td');label.append(el('span',names(key)),el('small',key,'scope'));if(s)label.title=t('counter.dates',{first:date(s.first_at),last:date(s.last_at),peak:date(s.max_at)});tr.append(label,el('td',value(c[key])),el('td',s?signed(s.delta):'—'));for(const k of ['min','mean','max','median','p95','stddev','n']){const cell=el('td',value(s?.[k]));if((k==='max'||k==='min')&&s)cell.append(el('small',new Date(s[k+'_at']*1000).toLocaleString(locale,{day:'2-digit',month:'2-digit',hour:'2-digit',minute:'2-digit'})));tr.append(cell);
        if(k==='mean'){const old=comparison?.summary[key],change=M.compareMean(s,old);for(const text of [value(old?.mean),change?signed(change.delta):'—',change&&M.finite(change.percent)?signed(change.percent)+' %':'—']){const extra=el('td',text,'comparison-col');extra.hidden=!compare;tr.append(extra);}}
      }$('details').append(tr);}
    const header=el('tr'),periodHeading=el('th',t('table.period'));periodHeading.hidden=!compare;header.append(periodHeading,el('th',t('observation')));for(const key of rawKeys)header.append(el('th',names(key)));$('observations').querySelector('thead').replaceChildren(header);
    const body=$('observations').querySelector('tbody');body.replaceChildren();
    for(const [period,observations] of [[t('comparison.selected'),data.points],[t('comparison.key'),comparison?.points||[]]])for(const p of observations){const row=el('tr'),periodCell=el('td',period);periodCell.hidden=!compare;row.append(periodCell,el('td',date(p.ts)));for(const key of rawKeys)row.append(el('td',value(p.counts[key])));body.append(row);}
    $('resolution').textContent=t('resolution',{samples:value(data.samples),points:value(data.points.length),interval:duration(data.bucket_seconds),gap:duration(q.longest_gap_seconds||0)});
    $('networks').replaceChildren();for(const n of data.streams||[]){const a=el('a',n.label);a.href=M.viewPath(n.id,currentView());if(n.id===stream)a.setAttribute('aria-current','page');$('networks').append(a);}
    $('updated').textContent=t('updated',{time:new Date((data.server_now||data.now)*1000).toLocaleTimeString(locale),zone:Intl.DateTimeFormat().resolvedOptions().timeZone});allDraw();
  }
  async function refresh(){if(busy)return;busy=true;$('refresh').disabled=true;
    $('compare').disabled=true;for(const id of ['earlier','later','live','share'])$(id).disabled=true;
    const query=new URLSearchParams({range});if(until!==null)query.set('end',String(until));if(compare)query.set('compare','1');
    try{const r=await fetch('/'+encodeURIComponent(stream)+'/data?'+query,{cache:'no-store',signal:AbortSignal.timeout(10000)});expired=r.status===400&&until!==null;if(!r.ok)throw Error();const incoming=await r.json();if(!Array.isArray(incoming.points)||!incoming.summary)throw Error();data=incoming;unavailable=false;expired=false;render();updateURL();}
    catch{unavailable=true;showUnavailable();}
    finally{busy=false;$('refresh').disabled=false;$('share').disabled=false;$('compare').disabled=false;$('live').disabled=until===null;$('later').disabled=until===null;$('earlier').disabled=!data||data.from<=data.retention_from;}
  }
  function showUnavailable(){
    $('notice').hidden=false;$('notice').textContent=t(expired?'notice.expired':'notice.unavailable');
    $('status').className='status stale';$('status').querySelector('span').textContent=t('status.unavailable');
  }
  function applyLanguage(){
    document.documentElement.lang=language;
    locale=I.locale(language);nf=new Intl.NumberFormat(locale,{maximumFractionDigits:2});
    for(const node of document.querySelectorAll('[data-i18n]'))node.textContent=t(node.dataset.i18n);
    for(const node of document.querySelectorAll('[data-i18n-aria]'))node.setAttribute('aria-label',t(node.dataset.i18nAria));
    for(const node of document.querySelectorAll('[data-i18n-title]'))node.title=t(node.dataset.i18nTitle);
    $('language').value=language;$('compare').checked=compare;$('share-status').textContent='';
    for(const button of document.querySelectorAll('[data-range]'))button.setAttribute('aria-pressed',String(button.dataset.range===range));
    for(const panel of panels.values()){
      panel.comparisonKey.hidden=!compare;panel.comparisonKey.textContent=t('comparison.key');
      panel.heading.textContent=t(panel.title);panel.description.textContent=t(panel.subtitle);
      panel.badgeNode.textContent=['calculated','ratio'].includes(panel.badge)?t('badge.'+panel.badge):panel.badge;
      panel.canvas.setAttribute('aria-label',t('chart.accessible',{title:t(panel.title)}));
      for(const [key,button] of panel.buttons)button.textContent=names(key);
    }
    if(data)render();
    if(unavailable)showUnavailable();
    for(const [id,panel] of panels)if(!panel.tip.hidden)showTip(id,80);
  }
  $('language').addEventListener('change',()=>{
    language=I.select($('language').value);
    try{I.save(window.localStorage,language);}catch{}
    applyLanguage();
  });
  for(const b of document.querySelectorAll('[data-range]'))b.addEventListener('click',()=>{if(busy)return;range=b.dataset.range;resetZoom();for(const p of document.querySelectorAll('[data-range]'))p.setAttribute('aria-pressed',String(p===b));refresh();});
  $('export').addEventListener('click',()=>{if(!data)return;const rows=[['timestamp_utc',...rawKeys],...data.points.map(p=>[new Date(p.ts*1000).toISOString(),...rawKeys.map(k=>p.counts[k]??'')])];const url=URL.createObjectURL(new Blob([rows.map(r=>r.join(',')).join('\r\n')+'\r\n'],{type:'text/csv;charset=utf-8'}));const a=el('a');a.href=url;a.download=`mediabot-${stream}-${data.range}-observations.csv`;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);});
  function navigate(direction){
    if(busy||!data)return;
    const endpoint=data.now+direction*(data.now-data.from);
    until=endpoint>=(data.server_now||data.now)-60?null:Math.max(data.retention_from+1,endpoint);
    resetZoom();refresh();
  }
  $('earlier').addEventListener('click',()=>navigate(-1));$('later').addEventListener('click',()=>navigate(1));
  $('live').addEventListener('click',()=>{if(busy)return;until=null;resetZoom();refresh();});
  $('compare').addEventListener('change',()=>{if(busy){$('compare').checked=compare;return;}compare=$('compare').checked;refresh();});
  $('share').addEventListener('click',async()=>{
    const shared=data?{range:data.range,end:data.now,compare}:currentView();
    const link=location.origin+M.viewPath(stream,shared);
    try{await navigator.clipboard.writeText(link);$('share-status').textContent=t('window.copied');}
    catch{$('share-status').textContent=t('window.copyFallback',{link});}
  });
  $('zero').addEventListener('change',allDraw);$('reset-zoom').addEventListener('click',resetZoom);$('refresh').addEventListener('click',refresh);
  applyLanguage();refresh();setInterval(()=>{if(!document.hidden&&!drag)refresh();},60000);
})();
