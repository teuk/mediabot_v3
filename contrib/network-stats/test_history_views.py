import hashlib
import http.client
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest

import network_stats as n


class HistoryViewsTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.now=int(time.time())
        self.h=n.History(self.root/'history.sqlite3')

    def add(self,ts,users,**extra):
        sample=dict(schema=1,sampled_at=ts,network='Libera',interval=300,counts=dict(users=users,**extra))
        self.h.ingest('libera',[sample],self.now)

    def populate(self):
        start=self.now-3600
        for offset,users in [(-3000,10),(-1800,20),(-300,30),(0,100),(300,200),(3600,300)]:
            self.add(start+offset,users,channels=0)

    def test_previous_window_is_disjoint_at_the_exact_boundary(self):
        self.populate();q=self.h.query('libera','1h',self.now,compare=True);p=q['comparison']
        self.assertEqual(q['summary']['users']['mean'],200)
        self.assertEqual(p['summary']['users']['mean'],20)
        self.assertEqual(q['samples'],3);self.assertEqual(p['samples'],3)
        current={x['ts'] for x in q['points']};previous={x['ts'] for x in p['points']}
        self.assertFalse(current&previous)
        self.assertIn(q['from'],current);self.assertNotIn(q['from'],previous)
        self.assertEqual(q['from'],p['until'])

    def test_pinned_window_never_uses_newer_samples(self):
        self.populate();end=self.now-2700
        q=self.h.query('libera','1h',self.now,until=end,compare=True)
        self.assertFalse(q['live']);self.assertEqual(q['now'],end)
        self.assertEqual(q['server_now'],self.now)
        self.assertEqual(q['latest']['counts']['users'],200)
        self.assertTrue(all(p['ts']<=end for p in q['points']))
        self.assertEqual(self.h.query('libera','1h',self.now)['latest']['counts']['users'],300)

    def test_live_request_keeps_legacy_fields_and_no_unrequested_comparison(self):
        self.populate();q=self.h.query('libera','1h',self.now)
        self.assertTrue(q['live']);self.assertEqual(q['now'],self.now)
        self.assertEqual(q['from'],self.now-3600);self.assertNotIn('comparison',q)
        self.assertEqual(q['first_available'],self.now-6600)
        self.assertEqual(q['summary']['channels']['mean'],0)

    def test_actual_clock_controls_retention_for_historical_queries(self):
        cutoff=self.now-n.RETENTION
        with self.h.connect() as db:
            db.execute('INSERT INTO samples VALUES (?,?,?,?,?)',('libera',cutoff-1,'Libera',300,'{"users":999}'))
        self.add(cutoff+1,7)
        q=self.h.query('libera','1h',self.now,until=cutoff+300,compare=True)
        self.assertEqual(q['samples'],1);self.assertTrue(q['quality']['retention_clipped'])
        self.assertEqual(q['comparison']['samples'],0)
        with self.h.connect() as db:self.assertEqual(db.execute('SELECT count(*) FROM samples WHERE ts<?',(cutoff,)).fetchone()[0],0)

    def test_90_day_comparison_does_not_invent_retained_history(self):
        self.add(self.now-10,42)
        q=self.h.query('libera','90d',self.now,compare=True)
        self.assertEqual(q['comparison']['samples'],0)
        self.assertEqual(q['comparison']['points'],[])
        self.assertEqual(q['comparison']['summary'],{})
        self.assertTrue(q['comparison']['quality']['retention_clipped'])

    def test_each_window_starts_without_an_invented_cross_boundary_rate(self):
        start=self.now-3600
        for offset,users in [(-600,10),(-300,20),(0,100),(300,110)]:self.add(start+offset,users)
        q=self.h.query('libera','1h',self.now,compare=True)
        self.assertIsNone(q['points'][0]['net_rate'])
        self.assertIsNone(q['comparison']['points'][0]['net_rate'])
        self.assertEqual(q['points'][1]['net_rate'],120)
        self.assertEqual(q['comparison']['points'][1]['net_rate'],120)

    def test_missing_and_zero_counters_stay_distinct_in_both_periods(self):
        self.populate();q=self.h.query('libera','1h',self.now,compare=True)
        for window in [q,q['comparison']]:
            self.assertEqual(window['summary']['channels']['min'],0)
            self.assertNotIn('operators',window['summary'])
            self.assertLessEqual(window['quality']['coverage_percent'],100)

    def test_historical_options_are_bounded_and_strictly_typed(self):
        for endpoint in [True,'1',self.now+1,self.now-n.RETENTION,-1]:
            with self.subTest(endpoint=endpoint),self.assertRaises(ValueError):self.h.query('libera','1h',self.now,until=endpoint)
        with self.assertRaises(ValueError):self.h.query('libera','1h',self.now,compare=1)

    def test_downsampled_periods_retain_raw_extrema_and_sample_counts(self):
        start=self.now-7200
        samples=[dict(schema=1,sampled_at=start+i*3,network='Libera',interval=300,counts={'users':10000 if i in (501,1801) else i}) for i in range(2401)]
        for offset in range(0,len(samples),256):self.h.ingest('libera',samples[offset:offset+256],self.now)
        q=self.h.query('libera','1h',self.now,compare=True)
        for period,expected in [(q,1201),(q['comparison'],1200)]:
            self.assertEqual(period['samples'],expected)
            self.assertLessEqual(len(period['points']),601)
            self.assertEqual(period['summary']['users']['max'],10000)

    def server(self):
        cfg={'database':str(self.root/'api.sqlite3'),'streams':{'libera':{'label':'Libera','token_sha256':hashlib.sha256(b'public-view-test').hexdigest()}}}
        server=n.Server(('127.0.0.1',0),cfg)
        threading.Thread(target=server.serve_forever,kwargs={'poll_interval':0.01},daemon=True).start()
        self.addCleanup(server.server_close);self.addCleanup(server.shutdown)
        return server

    def request(self,server,query):
        connection=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=3)
        connection.request('GET','/libera/data?'+query)
        response=connection.getresponse();body=response.read();connection.close()
        return response.status,json.loads(body)

    def test_http_historical_comparison_and_public_contract(self):
        server=self.server();end=self.now-60
        status,data=self.request(server,'range=1h&end='+str(end)+'&compare=1')
        self.assertEqual(status,200);self.assertFalse(data['live'])
        self.assertEqual(data['now'],end);self.assertEqual(data['stream'],'libera')
        self.assertIn('comparison',data);self.assertNotIn('token_sha256',json.dumps(data))

    def test_http_rejects_duplicates_unknowns_expired_and_future_endpoints(self):
        server=self.server()
        for query in ['range=1h&end=1&end=2','compare=1&compare=0','compare=yes','end=','end=-1','end=1e9','end=999999999999999999999','unknown=1','end='+str(self.now+86400),'end='+str(self.now-n.RETENTION)]:
            with self.subTest(query=query):self.assertEqual(self.request(server,query)[0],400)


if __name__=='__main__':unittest.main()
