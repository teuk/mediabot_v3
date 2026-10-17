'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const M=require('./static/dashboard.js');
test('comparison requires two real samples in both periods and keeps zero baselines honest',()=>{
 assert.deepEqual(M.compareMean({n:2,mean:120},{n:3,mean:100}),{delta:20,percent:20});
 assert.deepEqual(M.compareMean({n:2,mean:0},{n:2,mean:100}),{delta:-100,percent:-100});
 assert.deepEqual(M.compareMean({n:2,mean:20},{n:2,mean:0}),{delta:20,percent:undefined});
 for(const previous of [null,{n:0,mean:0},{n:1,mean:100},{n:2,mean:NaN}])assert.equal(M.compareMean({n:2,mean:10},previous),undefined);
 assert.equal(M.compareMean({n:1,mean:10},{n:2,mean:100}),undefined);
});
test('view URLs retain only typed public options and never include arbitrary query material',()=>{
 assert.deepEqual(M.viewOptions('?range=7d&end=1792000000&compare=1&private=hidden'),{range:'7d',end:1792000000,compare:true});
 assert.deepEqual(M.viewOptions('?range=bad&end=<script>&compare=yes'),{range:'24h',end:null,compare:false});
 assert.equal(M.viewPath('libera',{range:'24h',end:null,compare:false}),'/libera');
 assert.equal(M.viewPath('epiknet',{range:'7d',end:1792000000,compare:true}),'/epiknet?range=7d&end=1792000000&compare=1');
 assert.equal(M.viewPath('a/b',{range:'1h',end:null,compare:false}),'/a%2Fb?range=1h');
});
test('previous-period tooltips select actual nearby samples and refuse gaps',()=>{
 const points=[{ts:1000,interval:300},{ts:1300,interval:300},{ts:3000,interval:300}];
 assert.equal(M.nearest(points,1290),points[1]);assert.equal(M.nearest(points,2200),undefined);
 assert.equal(M.nearest([],1000),undefined);
});
test('English and French explain previous means, sparse history and fixed-duration alignment',()=>{
 for(const lang of ['en','fr'])for(const key of ['comparison.toggle','comparison.info','comparison.empty','comparison.mean','comparison.delta','comparison.percent','comparison.sample','method.comparison','window.earlier','window.later','window.share','notice.historicalEmpty','notice.expired']){
  assert.ok(Object.hasOwn(M.i18n.messages[lang],key));
 }
 assert.match(M.i18n.text('en','method.comparison'),/at least two observations/);
 assert.match(M.i18n.text('fr','method.comparison'),/au moins deux observations/);
});
