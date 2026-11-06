# t/cases/902_mb693_rss_repository_polling.t
use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

use Mediabot::RSS::Fetcher;
use Mediabot::RSS::Repository;
use Mediabot::RSS::Poller;
use Mediabot::RSS::Runtime;
use MB881OutputFixture;
use File::Temp qw(tempdir);
use IO::Async::Loop;
use DBI;
use DBD::SQLite::Constants qw(SQLITE_SELECT SQLITE_DENY SQLITE_OK);
use JSON::PP;
use POSIX ();
use Time::Local ();

# Native DBI queries and cursors. Adapt only MySQL's date functions to SQLite;
# the driver/authorizer and DBI set_err inject errors at the actual boundaries.
{
    package MB1080::DBI;
    our @ISA=('DBI');
    package MB1080::DBI::db;
    our @ISA=('DBI::db');
    sub prepare {
        my ($db,$sql,@rest)=@_;
        $sql =~ s/\bSECOND\b/'SECOND'/g;
        $sql =~ s/\bWHERE\b/WHERE mb1080_gate() AND/i
            if $sql =~ /^\s*SELECT/ && ($db->{private_fault}//'') eq 'execute';
        my $sth=$db->SUPER::prepare($sql,@rest);
        if ($sth && $db->{private_probe}) {
            $sth->{private_read}=$sql =~ /^\s*SELECT/ ? 1:0;
            push @{$db->{private_statements}},$sth;
        }
        return $sth;
    }
    package MB1080::DBI::st;
    our @ISA=('DBI::st');
    sub execute {
        my ($sth,@bind)=@_;
        $sth->{private_binds}=\@bind;
        return $sth->SUPER::execute(@bind);
    }
    sub _failed_fetch {
        my ($sth)=@_;return 0 unless $sth->{private_read};
        my $fault=$sth->{Database}{private_fault}//'';
        my $n=++$sth->{private_fetches};
        return ($fault eq 'fetch_empty' && $n==1) || ($fault eq 'fetch_partial' && $n==2);
    }
    sub fetchrow_hashref {
        my $sth=shift;
        return $sth->set_err(1,'private cursor diagnostic') if $sth->_failed_fetch;
        return $sth->SUPER::fetchrow_hashref(@_);
    }
    sub fetchrow_array {
        my $sth=shift;
        if ($sth->_failed_fetch) {$sth->set_err(1,'private cursor diagnostic');return}
        return $sth->SUPER::fetchrow_array(@_);
    }
    sub finish {
        my $sth=shift;++$sth->{private_finished};
        my $rv=$sth->SUPER::finish(@_);
        $sth->set_err(undef,undef); # cleanup must not erase the already decided status
        die "private cleanup diagnostic\n"
            if $sth->{private_read} && $sth->{Database}{private_cleanup_throw};
        return $rv;
    }
}

my $json902=JSON::PP->new->canonical;
sub _fixture1080 {
    my ($raise)=@_;
    my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',
        {RaiseError=>$raise,PrintError=>0,RootClass=>'MB1080::DBI'});
    my $epoch=sub {
        return undef unless defined $_[0];
        my @d=$_[0]=~/^(\d+)-(\d+)-(\d+) (\d+):(\d+):(\d+)$/;
        return Time::Local::timegm($d[5],$d[4],$d[3],$d[2],$d[1]-1,$d[0]);
    };
    $db->sqlite_create_function('NOW',0,sub {'2026-11-03 12:00:00'});
    $db->sqlite_create_function('GREATEST',2,sub {$_[0]>$_[1]?$_[0]:$_[1]});
    $db->sqlite_create_function('TIMESTAMPADD',3,sub {
        return undef unless defined $_[2];
        return POSIX::strftime('%Y-%m-%d %H:%M:%S',gmtime($epoch->($_[2])+$_[1]));
    });
    $db->sqlite_create_function('TIMESTAMPDIFF',3,sub {
        return undef unless defined($_[1]) && defined($_[2]);
        return $epoch->($_[2])-$epoch->($_[1]);
    });
    $db->sqlite_create_function('mb1080_gate',0,sub {die "private execute diagnostic\n"});
    $db->do('CREATE TABLE CHANNEL (id_channel INTEGER PRIMARY KEY,name TEXT)');
    $db->do(q{CREATE TABLE RSS_FEED (id_rss_feed INTEGER PRIMARY KEY,id_channel INTEGER,
        label TEXT,url TEXT,url_hash TEXT,enabled INTEGER,poll_interval INTEGER,
        announce_limit INTEGER,etag TEXT,last_modified TEXT,last_poll_at TEXT,
        last_success_at TEXT,last_error_at TEXT,last_error TEXT,created_by INTEGER,
        created_by_nick TEXT,created_at TEXT,updated_at TEXT)});
    $db->do(q{CREATE TABLE RSS_ITEM (id_rss_item INTEGER PRIMARY KEY,id_rss_feed INTEGER,
        item_key TEXT,title TEXT,url TEXT,published_raw TEXT,seen_at TEXT,announced_at TEXT)});
    $db->do(q{INSERT INTO CHANNEL VALUES (1,'#one'),(2,'#two')});
    $db->do(q{INSERT INTO RSS_FEED (id_rss_feed,id_channel,label,url,enabled,poll_interval,announce_limit,last_poll_at,last_success_at)
        VALUES (1,1,'Alpha','https://one.example/rss',1,600,3,'2026-11-03 11:00:00','old'),
               (2,1,'Bravo','https://two.example/rss',1,600,3,'2026-11-03 11:59:00','old'),
               (3,2,'Charlie','https://three.example/rss',0,600,3,NULL,'old'),
               (4,2,'Delta','https://four.example/rss',1,600,3,NULL,NULL)});
    $db->do(q{INSERT INTO RSS_ITEM (id_rss_item,id_rss_feed,title,announced_at)
        VALUES (1,1,'Old one',NULL),(2,1,'Old two',NULL),(3,1,'Latest',NULL),
               (4,2,'Other feed',NULL),(5,1,'Acknowledged','old')});
    $db->{private_statements}=[];
    return (Mediabot::RSS::Repository->new(dbh=>$db),$db);
}
my @reads1080=(
    ['channel lookup',sub {$_[0]->channel_id('#one')}],
    ['list',sub {$_[0]->list_feeds('#one')}],
    ['get',sub {$_[0]->get_feed('#one','Alpha')}],
    ['due-feed',sub {$_[0]->list_due_feeds(1)}],
    ['enabled lookup',sub {$_[0]->is_feed_enabled(1)}],
    ['pending',sub {$_[0]->pending_items(1,2)}],
    ['latest-pending',sub {$_[0]->paced_pending_items(1)}],
);
sub _invoke1080 {
    my ($repo,$db,$call,$fault,$cleanup)=@_;
    $db->{private_fault}=$fault//'';$db->{private_cleanup_throw}=$cleanup//0;
    $db->{private_probe}=1;
    $db->sqlite_set_authorizer(sub {$_[0]==SQLITE_SELECT?SQLITE_DENY:SQLITE_OK})
        if ($fault//'') eq 'prepare';
    my $value=eval {$call->($repo)};my $error=$@;
    $db->sqlite_set_authorizer(undef);
    $db->{private_probe}=0;$db->{private_fault}='';$db->{private_cleanup_throw}=0;
    return ($value,$error);
}
sub _pending1080 {
    my ($db)=@_;
    return join(',',map {$_->[0]} @{$db->selectall_arrayref(
        'SELECT id_rss_item FROM RSS_ITEM WHERE id_rss_feed=1 AND announced_at IS NULL ORDER BY 1')});
}
sub _clean1080 {
    my ($db)=@_;
    my $ok=!grep {!$_->{private_finished} || $_->{Active}} @{$db->{private_statements}};
    $db->{private_statements}=[];$db->disconnect;
    return $ok;
}

{
    package FakeTiny902;
    sub get {
        my ($self, $url, $args) = @_;
        $self->{url} = $url;
        $self->{args} = $args;
        return { success=>1, status=>200, headers=>{}, content=>'<rss><channel><title>x</title></channel></rss>' };
    }
}

sub _slurp902 {
    my ($p)=@_; open my $fh,'<',$p or die $!; local $/; return <$fh>;
}

{
    package MB1111::DB;
    sub ensure_connected { $_[0]{parent_handle} }
    sub connect_isolated_handle { return (undef, 'private connection detail') }

    package MB1111::InlineWorker;
    sub start {
        my ($class,%job)=@_;
        $job{on_done}->({ok=>1,value=>$job{child}->()});
        return bless {}, $class;
    }
}
sub _runtime1111 {
    my ($db)=@_;
    return Mediabot::RSS::Runtime->new(
        bot=>{_start_time=>1, db=>bless({parent_handle=>$db},'MB1111::DB')},
        loop=>bless({},'MB1111::Loop'), pacing=>bless({},'Pacing1080'),
        worker_class=>'MB1111::InlineWorker', max_workers=>1,
    );
}
sub _failure_state1111 {
    my ($db)=@_;
    return $db->selectrow_arrayref(q{
        SELECT last_poll_at,last_error_at,last_error,last_success_at,etag,last_modified
          FROM RSS_FEED WHERE id_rss_feed=1});
}
sub _seed_validators1111 {
    my ($db)=@_;
    $db->do(q{UPDATE RSS_FEED SET etag='saved',last_modified='prior' WHERE id_rss_feed=1});
}

return sub {
    my ($assert) = @_;

    my %seen;
    my $rss = '<rss><channel><title>x</title><item><title>A</title><link>https://example.org/a</link><guid>a</guid></item></channel></rss>';
    my $res = Mediabot::RSS::Fetcher::fetch_feed_once(
        'https://feed.example/rss',
        resolver => sub { ['93.184.216.34'] },
        requester => sub {
            my ($url,%opts)=@_; %seen=%opts;
            return { success=>1,status=>200,headers=>{ etag=>'"abc"','last-modified'=>'Sat, 23 Aug 2026 09:00:00 GMT' },content=>$rss };
        },
        etag => '"old"', last_modified => 'Fri, 22 Aug 2026 09:00:00 GMT',
    );
    $assert->is($json902->encode([$res->{ok}?1:0,$seen{request_headers},$res->{etag},$res->{last_modified}]),
        $json902->encode([1,{'If-None-Match'=>'"old"','If-Modified-Since'=>'Fri, 22 Aug 2026 09:00:00 GMT'},
            '"abc"','Sat, 23 Aug 2026 09:00:00 GMT']),
        'mb693-902: parsed conditional 200 forwards both old validators and returns both new validators');

    my $nm = Mediabot::RSS::Fetcher::fetch_feed_once(
        'https://feed.example/rss',
        resolver => sub { ['93.184.216.34'] },
        requester => sub { return { success=>0,status=>304,headers=>{etag=>'"abc"'},content=>'' } },
        etag => '"abc"',
    );
    $assert->ok($nm->{ok} && $nm->{not_modified},
        'mb693-902: HTTP 304 succeeds without trying to parse an empty body');

    my $tiny = bless {}, 'FakeTiny902';
    {
        no warnings qw(redefine once);
        local *HTTP::Tiny::new = sub { return $tiny };
        Mediabot::RSS::Fetcher::_default_requester(
            'https://feed.example/rss',
            validated_addresses => ['93.184.216.34'],
            request_headers => {
                'If-None-Match' => '"wire"',
                'If-Modified-Since' => 'Sat, 23 Aug 2026 09:00:00 GMT',
                'Host' => 'forbidden.example',
            },
        );
    }
    $assert->is($json902->encode([$tiny->{args}{headers}{'If-None-Match'},
            $tiny->{args}{headers}{'If-Modified-Since'},exists($tiny->{args}{headers}{Host})?1:0]),
        $json902->encode(['"wire"','Sat, 23 Aug 2026 09:00:00 GMT',0]),
        'mb693-902: native requester emits both conditional headers and rejects injected Host');

    my $repo = _slurp902('Mediabot/RSS/Repository.pm');
    $assert->ok($repo =~ /sub insert_item .*?INSERT IGNORE INTO RSS_ITEM/s
        && $repo =~ /announced_at\)\s*VALUES \(\?, \?, \?, \?, \?, IF\(\? = 1, NOW\(\), NULL\)\)/s
        && $repo =~ /sub mark_announced .*?SET announced_at = NOW\(\)/s
        && $repo =~ /sub _record_poll_success .*?last_success_at = NOW\(\).*?\$validators/s
        && $repo =~ /sub record_poll_error .*?last_error_at = NOW\(\).*?last_error = \?/s,
        'mb693-902: dedup, baseline suppression, acknowledgement, success validators and isolated errors retain their write contracts');

    {
        my ($r,$db)=_fixture1080(1);$db->{private_probe}=1;
        my $list=$r->list_feeds('#one');my $get=$r->get_feed('#one','Alpha');
        my $due=$r->list_due_feeds(1000);my $pending=$r->pending_items(1,0);
        my @observed=($r->channel_id('#one'),$r->channel_id('#missing'),
            [map {[$_->{label},0+$_->{item_count},0+$_->{pending_count},0+$_->{next_poll_in}]} @$list],
            [$get->{id_rss_feed},$get->{channel},$get->{label}],$r->get_feed('#one','Missing'),
            [map {$_->{id_rss_feed}} @$due],$r->is_feed_enabled(1),$r->is_feed_enabled(3),
            $r->is_feed_enabled(99),[map {$_->{id_rss_item}} @$pending]);
        # Returned hash mutations cannot alter subsequent database reads.
        $get->{label}='mutated';$list->[0]{label}='mutated';
        push @observed,$r->get_feed('#one','Alpha')->{label};
        my $latest=$r->paced_pending_items(1);
        $db->{private_probe}=0;
        push @observed,[map {$_->{id_rss_item}} @$latest],_pending1080($db);
        push @observed,_clean1080($db)?1:0;
        $assert->is($json902->encode(\@observed),$json902->encode(
            [1,undef,[['Alpha',4,3,0],['Bravo',1,1,540]],[1,'#one','Alpha'],undef,
             [4,1],1,0,0,[1],'Alpha',[3],'3',1]),
            'MB1080: native reads preserve channel scope, counts, empty values, due order, limits, detached rows and paced suppression');
    }
    for my $phase (['prepare','execute'],['fetch_empty','fetch_partial']) {
        my @bad;
        for my $raise (0,1) {for my $fault (@$phase) {for my $read (@reads1080) {
            my ($r,$db)=_fixture1080($raise);
            my ($value,$error)=_invoke1080($r,$db,$read->[1],$fault);
            my $stage=$fault=~/^fetch/ ? 'fetch':$fault;
            my $unchanged=_pending1080($db) eq '1,2,3';
            my $clean=_clean1080($db);
            push @bad,[$raise,$fault,$read->[0],$error,defined($value)?1:0,$unchanged?1:0,$clean?1:0]
                unless !defined($value) && $error eq "RSS $read->[0] $stage failed\n" && $unchanged && $clean;
        }}}
        $assert->is($json902->encode(\@bad),'[]',
            'MB1080: every native read rejects '.join('/',@$phase).' in both DBI error modes before publishing rows or discarding paced candidates');
    }
    {
        my @bad;
        for my $raise (0,1) {for my $fault ('','fetch_partial') {for my $read (@reads1080) {
            my ($r,$db)=_fixture1080($raise);
            my ($value,$error)=_invoke1080($r,$db,$read->[1],$fault,1);
            my $expected=$fault eq '' ? defined($value) && $error eq ''
                : !defined($value) && $error eq "RSS $read->[0] fetch failed\n";
            my $clean=_clean1080($db);
            push @bad,[$raise,$fault,$read->[0],$error] unless $expected && $clean;
        }}}
        $assert->is($json902->encode(\@bad),'[]',
            'MB1080: native finish followed by an exception cannot change a successful or failed read decision');
    }
    {
        my @observed;
        for my $paced (0,1) {
            my ($r,$db)=_fixture1080(0);
            my $pacing=$paced ? bless({},'Pacing1080'):undef;
            my $poller=Mediabot::RSS::Poller->new(repo=>$r,pacing=>$pacing,
                fetcher=>sub {{ok=>1,not_modified=>1}});
            my $feed={id_rss_feed=>1,url=>'https://one.example/rss',channel=>'#one',announce_limit=>3,last_success_at=>'old'};
            my $failed;_invoke1080($r,$db,sub {$failed=$poller->poll_feed($feed)},'fetch_partial');
            push @observed,[$failed->{ok}?1:0,$failed->{error},exists($failed->{pending})?1:0,_pending1080($db)];
            my $retry=$poller->poll_feed($feed);
            push @observed,[$retry->{ok}?1:0,[map {$_->{id_rss_item}} @{$retry->{pending}}],_pending1080($db)];
            _clean1080($db);
        }
        $assert->is($json902->encode(\@observed),$json902->encode(
            [[0,'repository_error',0,'1,2,3'],[1,[1,2,3],'1,2,3'],
             [0,'repository_error',0,'1,2,3'],[1,[3],'3']]),
            'MB1080: real poller reports failed reads without pending output or paced data loss, then recovers on the next poll');
    }
    {
        my ($r,$db)=_fixture1080(1);
        _seed_validators1111($db);
        $db->do('UPDATE RSS_FEED SET enabled=0 WHERE id_rss_feed=4');
        my $runtime=_runtime1111($db);
        my $started=$runtime->tick;
        my $retry=$runtime->tick;
        my $failed=_failure_state1111($db);
        $db->sqlite_create_function('NOW',0,sub {'2026-11-03 12:10:00'});
        my @due=map {$_->{id_rss_feed}} @{$r->list_due_feeds(20)};
        $assert->is($json902->encode([$started,$retry,$runtime->inflight_count,$runtime->queued_count,$failed,\@due]),
            $json902->encode([1,0,0,0,['2026-11-03 12:00:00','2026-11-03 12:00:00',
                'RSS poll failed (isolated_db)','old','saved','prior'],[2,1]]),
            'MB1111: child DB failure is recorded by the parent, waits the feed interval and preserves the accepted body');
    }
    {
        my @observed;
        for my $fail_write (0,1) {
            my ($r,$db)=_fixture1080(1);
            _seed_validators1111($db);
            $db->do('CREATE TABLE poll_errors (note TEXT)');
            $db->do(q{CREATE TRIGGER count_errors AFTER UPDATE OF last_error ON RSS_FEED
                BEGIN INSERT INTO poll_errors VALUES (NEW.last_error); END});
            if ($fail_write) {
                $db->do(q{CREATE TRIGGER refuse_error BEFORE UPDATE OF last_error ON RSS_FEED
                    BEGIN SELECT RAISE(ABORT,'private writer detail'); END});
            }
            my $feed=$r->get_feed('#one','Alpha');
            my $p=Mediabot::RSS::Poller->new(repo=>$r,
                fetcher=>sub {{ok=>0,error=>'http_status',detail=>'503'}});
            my $result=$p->poll_feed($feed);
            $db->do('DROP TRIGGER refuse_error') if $fail_write;
            my $runtime=_runtime1111($db);
            my $handled=$runtime->_worker_done($feed,{ok=>1,value=>$result});
            push @observed,[$handled,$runtime->queued_count,
                $db->selectcol_arrayref('SELECT note FROM poll_errors'),_failure_state1111($db)];
        }
        my @expected;
        for my $note ('http_status: 503','RSS poll failed (http_status)') {
            push @expected,[0,0,[$note],['2026-11-03 12:00:00','2026-11-03 12:00:00',
                $note,'old','saved','prior']];
        }
        $assert->is($json902->encode(\@observed),$json902->encode(\@expected),
            'MB1111: record a fetch failure once, retry a refused child write and keep driver details out of the fallback');
    }

    MB881OutputFixture::with_policy(sub {
        my @observed;
        no warnings qw(redefine once);
        local *MB881::IRC::is_connected = sub {$_[0]{connected}};
        my $send=MB881::IRC->can('do_PRIVMSG');
        local *MB881::IRC::do_PRIVMSG = sub {return $_[0]{connected} ? $send->(@_) : undef};
        for my $blocked (qw(flood offline)) {
            my ($repo,$db)=_fixture1080(1);
            $db->do('UPDATE RSS_ITEM SET item_key=? WHERE id_rss_item=1',undef,'a'x64);
            my $bot=MB881OutputFixture::new_bot();
            $bot->{dbh}=$db;
            $bot->{db}=bless {parent_handle=>$db},'MB1111::DB';
            # Only RSS uses the fixture database; output has a warm empty
            # badword cache, just as it would after a successful empty read.
            $bot->{_badword_cache}{'#one'}={ts=>time(),words=>[]};
            $bot->{policy}{AntiFlood}=1;
            $bot->{blocked}=($blocked eq 'flood');
            $bot->{irc}{connected}=($blocked ne 'offline');
            my $dir=tempdir(CLEANUP=>1);
            my $runtime=Mediabot::RSS::Runtime->new(bot=>$bot,
                loop=>IO::Async::Loop->new,
                pacing=>Mediabot::RSS::Pacing->new(path=>"$dir/pacing.json"));
            my $attempt=sub {
                my $pending=$repo->pending_items(1,1)->[0];
                return unless $pending && ($pending->{item_key}//'') eq 'a'x64;
                $runtime->_enqueue_announcements(feed_id=>1,channel=>'#one',
                    items=>[{item_key=>$pending->{item_key},line=>$pending->{title}}]);
            };
            $attempt->();
            push @observed,[$blocked,_pending1080($db),
                scalar(@{$bot->{irc}{wire}}),exists($bot->{_flood_outq})?1:0];
            $bot->{blocked}=0;
            $bot->{irc}{connected}=1;
            $attempt->();
            push @observed,[_pending1080($db),
                [map {[$_->{target},$_->{text}]} @{$bot->{irc}{wire}}],$runtime->queued_count];
            $db->disconnect;
        }
        $assert->is($json902->encode(\@observed),$json902->encode([
            ['flood','1,2,3',0,0],['2,3',[['#one','Old one']],0],
            ['offline','1,2,3',0,0],['2,3',[['#one','Old one']],0],
        ]), 'MB1122: unpaced RSS acknowledges only an immediate connected send; AntiFlood and offline attempts remain pending for the next poll');
    });
};

{ package Pacing1080; sub status {{active=>1}} }
