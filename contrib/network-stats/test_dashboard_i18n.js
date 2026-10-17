'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path');
const {i18n:I}=require('./static/dashboard.js');

test('English is the default and only explicit French selects French',()=>{
  for(const stored of [null,undefined,'','de','fr-FR','EN','<script>','__proto__']){
    assert.equal(I.read({getItem:()=>stored}),'en');
  }
  assert.equal(I.read({getItem:()=> 'fr'}),'fr');
  assert.equal(I.read({getItem:()=> 'en'}),'en');
  assert.equal(I.locale('fr'),'fr-FR');assert.equal(I.locale('en'),'en-GB');
  assert.equal(new Intl.NumberFormat(I.locale('en')).format(31021),'31,021');
  assert.equal(new Intl.NumberFormat(I.locale('fr')).format(31021),'31\u202f021');
});

test('one preference is shared across pages and unavailable storage never breaks rendering',()=>{
  const store=new Map(),storage={getItem:key=>store.get(key),setItem:(key,value)=>store.set(key,value)};
  assert.equal(I.save(storage,'fr'),true);assert.equal(I.read(storage),'fr');
  assert.deepEqual([...store],[[I.storageKey,'fr']]);
  assert.equal(I.save(storage,'en'),true);assert.equal(I.read(storage),'en');
  const blocked={getItem(){throw new Error('storage blocked');},setItem(){throw new Error('storage blocked');}};
  assert.equal(I.read(blocked),'en');assert.equal(I.save(blocked,'fr'),false);
});

test('English and French catalogues cover identical nonempty messages and interpolation fields',()=>{
  const keys=Object.keys(I.messages.en).sort();assert.ok(keys.length>100);
  assert.deepEqual(Object.keys(I.messages.fr).sort(),keys);
  const fields=text=>[...text.matchAll(/\{([A-Za-z_]+)\}/g)].map(m=>m[1]).sort();
  for(const key of keys){
    assert.ok(I.messages.en[key].trim(),key);assert.ok(I.messages.fr[key].trim(),key);
    assert.deepEqual(fields(I.messages.en[key]),fields(I.messages.fr[key]),key);
  }
  assert.equal(I.text('en','subtitle.live',{network:'Libera',minutes:5}),'Libera · /LUSERS every 5 min · Browser local time');
  assert.equal(I.text('fr','subtitle.live',{network:'Libera',minutes:5}),'Libera · /LUSERS toutes les 5 min · Horaires du navigateur');
});

test('every static text, accessible label and tooltip key exists with English HTML fallback',()=>{
  const html=fs.readFileSync(path.join(__dirname,'static/index.html'),'utf8');
  assert.match(html,/<html lang="en">/);
  const keys=[...html.matchAll(/data-i18n(?:-aria|-title)?="([^"]+)"/g)].map(m=>m[1]);
  assert.ok(keys.length>45);
  for(const key of keys)assert.ok(Object.hasOwn(I.messages.en,key),key);
  for(const m of html.matchAll(/<([a-z0-9]+)\b[^>]*data-i18n="([^"]+)"[^>]*>([^<]*)<\//g)){
    assert.equal(m[3],I.messages.en[m[2]],m[2]);
  }
  assert.match(html,/<label[^>]*for="language"/);
  assert.match(html,/<option value="en" lang="en">English<\/option>/);
  assert.match(html,/<option value="fr" lang="fr">Français<\/option>/);
});

test('all eleven charts and every raw or derived counter have both language labels',()=>{
  for(const id of ['users','channels','net','visibility','operators','servers','local','unknown','density','channels-ratio','operator-ratio']){
    for(const suffix of ['title','subtitle'])assert.ok(I.messages.en['chart.'+id+'.'+suffix],id);
  }
  for(const counter of ['users','visible_users','invisible_users','channels','operators','servers','unknown_connections','local_users','local_users_max','local_servers','global_users','users_max','net_rate','invisible_pct','visible_pct','users_per_channel','users_per_server','operators_per_1000','local_pct']){
    assert.ok(I.messages.en['metric.'+counter],counter);
  }
});

test('missing, stale and failed publication states provide useful text in both languages',()=>{
  for(const lang of ['en','fr']){
    for(const key of ['connecting','notice.empty','notice.stale','notice.unavailable','status.empty','status.stale','status.unavailable','empty.waiting','empty.counter','empty.hidden','empty.primary','chart.accessible']){
      assert.ok(I.text(lang,key).length>8,key);
    }
  }
  assert.match(I.text('en','notice.unavailable'),/retained/);
  assert.match(I.text('fr','notice.unavailable'),/conservées/);
});

test('translated display does not change the machine-readable UTC CSV schema',()=>{
  const source=fs.readFileSync(path.join(__dirname,'static/dashboard.js'),'utf8');
  assert.match(source,/\[\['timestamp_utc',\.\.\.rawKeys\]/);
  assert.match(source,/new Date\(p.ts\*1000\)\.toISOString\(\)/);
  assert.equal(I.text('en','counter.dates',{first:'A',last:'B',peak:'C'}),'First: A · Last: B · Peak: C');
  assert.equal(I.text('fr','counter.dates',{first:'A',last:'B',peak:'C'}),'Première : A · Dernière : B · Pic : C');
});
