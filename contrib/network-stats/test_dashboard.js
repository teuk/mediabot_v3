'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const M=require('./static/dashboard.js');
const p=(ts,counts,interval=300)=>({ts,counts,interval});
test('ratios require both counters in the same observation and a positive denominator',()=>{
  const d=M.derived(p(1000,{users:100,visible_users:25,invisible_users:75,channels:20,servers:4,operators:2,local_users:40}));
  assert.equal(d.invisible_pct,75);assert.equal(d.visible_pct,25);assert.equal(d.users_per_channel,5);assert.equal(d.users_per_server,25);assert.equal(d.operators_per_1000,20);assert.equal(d.local_pct,40);
  assert.equal(M.derived(p(1000,{users:0,channels:0})).users_per_channel,undefined);
  assert.equal(M.derived(p(1000,{users:100,invisible_users:75})).invisible_pct,undefined);
});
test('net rate is signed and uses elapsed time; disconnected intervals are not invented activity',()=>{
  assert.equal(M.derived(p(600,{users:110}),p(300,{users:100})).net_rate,120);
  assert.equal(M.derived(p(600,{users:90}),p(300,{users:100})).net_rate,-120);
  assert.equal(M.derived(p(5000,{users:110}),p(300,{users:100})).net_rate,undefined);
  assert.equal(M.derived(p(300,{users:110}),p(300,{users:100})).net_rate,undefined);
});
test('plots split at absent counters and long gaps while retaining explicit zero',()=>{
  const ps=[p(0,{users:0}),p(300,{users:2}),p(600,{}),p(900,{users:4}),p(5000,{users:5})];
  assert.deepEqual(M.segments(ps,'users').map(s=>s.map(p=>p.ts)),[[0,300],[900],[5000]]);
  assert.deepEqual(M.segments(ps,'users',2000).map(s=>s.map(p=>p.ts)),[[0,300],[900,5000]]);
  const gap=p(600,{users:3});gap.gap_before=true;
  assert.deepEqual(M.segments([p(0,{users:2}),gap],'users',10000).map(s=>s.length),[1,1]);
});
