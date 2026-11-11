use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::ChannelLog::Reader ();
{
    package MB1039::DBI; our @ISA = ('DBI');
    package MB1039::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db,$sql,@rest) = @_;
        my $sth = $db->SUPER::prepare($sql,@rest);
        if ($sth && $db->{private_ready} && $sql =~ /FROM\s+(CHANNEL_LOG|archive\.CHANNEL_LOG_ARCHIVE)\b/) {
            $sth->{private_source} = $1;
            $sth->{private_rows} = 0;
            push @{$db->{private_prepared}},$1;
        }
        return $sth;
    }
    package MB1039::DBI::st; our @ISA = ('DBI::st');
    sub execute {
        my ($sth,@args) = @_;
        if (defined($sth->{private_source})
                && ($sth->{Database}{private_execute_fault}//'') eq $sth->{private_source}) {
            return $sth->set_err(902,'fixture history execute failure');
        }
        return $sth->SUPER::execute(@args);
    }
    sub fetchrow_hashref {
        my ($sth,@args) = @_;
        my $db = $sth->{Database};
        if (defined($sth->{private_source}) && ($db->{private_fault_source}//'') eq $sth->{private_source}
                && $sth->{private_rows} == $db->{private_after}) {
            return $sth->set_err(901,'fixture history fetch failure');
        }
        my $row = $sth->SUPER::fetchrow_hashref(@args);
        $sth->{private_rows}++ if $row && defined $sth->{private_source};
        return $row;
    }
    sub finish {
        my ($sth) = @_;
        my $source = $sth->{private_source};
        $sth->{Database}{private_finished}{$source} = 1 if defined $source;
        my $ok = $sth->SUPER::finish;
        $sth->set_err(undef,undef); # A cleanup must not erase the failed-read decision.
        die "fixture cleanup failure\n" if defined($source) && $sth->{Database}{private_cleanup_failure};
        return $ok;
    }
    package MB1039::Conf;
    sub get {$_[0]{$_[1]}}
    package MB1039::Log;
    sub log {push @{$_[0]{entries}},[@_[1,2]];1}
}
$INC{'MB1039/DBI.pm'} = __FILE__;
my (@warnings,@wire,@audit); local $SIG{__WARN__} = sub {push @warnings,@_};
no warnings qw(redefine once);
local *Mediabot::UserCommands::botNotice = sub {push @wire,['notice',$_[1],$_[2]];1};
local *Mediabot::UserCommands::botPrivmsg = sub {push @wire,['public',$_[1],$_[2]];1};
local *Mediabot::UserCommands::logBot = sub {push @audit,[@_[2..$#_]];1};
sub fixture_1412 {
    my ($raise,$source,$after,$empty) = @_;
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:','','',{
        RootClass=>'MB1039::DBI',RaiseError=>$raise,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
    $db->do(q{ATTACH DATABASE ':memory:' AS archive});
    $db->do('CREATE TABLE CHANNEL(id_channel INTEGER,name TEXT)');
    $db->do(q{INSERT INTO CHANNEL VALUES(7,'#test'),(9,'#other')});
    for my $table ('CHANNEL_LOG','archive.CHANNEL_LOG_ARCHIVE') {
        $db->do("CREATE TABLE $table(id_channel_log INTEGER,id_channel INTEGER,nick TEXT,publictext TEXT,event_type TEXT,n INTEGER)");
        next if $empty;
        my $offset = $table eq 'CHANNEL_LOG' ? 0:20;
        $db->do("INSERT INTO $table VALUES(?,?,?,?,?,?)",undef,@$_) for
            [$offset+1,7,'alice','alpha beta','public',$offset+10],
            [$offset+2,7,'alice','gamma delta','public',$offset+20],
            [$offset+3,9,'foreign','foreign channel','public',999];
    }
    $db->{private_fault_source} = $source;
    $db->{private_after} = $after;
    $db->{private_prepared} = [];
    $db->{private_finished} = {};
    $db->{private_ready} = 1;
    my $bot = Mediabot->new({dbh=>$db});
    $bot->{conf} = bless({'mysql.CHANNEL_LOG_ARCHIVE_DBNAME'=>'archive',
        'mysql.CHANNEL_LOG_ARCHIVE_CONTENT_DAYS'=>7,'mysql.CHANNEL_LOG_ARCHIVE_PRESENCE_DAYS'=>7},'MB1039::Conf');
    $bot->{logger} = bless({entries=>[]},'MB1039::Log');
    return ($bot,$db);
}
sub gather_1412 {
    my ($bot,$db,$callback,$direct) = @_;
    my ($status,$error); my @rows;
    my $ok = eval {
        my $entry = $direct ? \&Mediabot::ChannelLog::Reader::channel_log_gather
            : \&Mediabot::Helpers::channel_log_gather;
        $status = $entry->($bot,$db,'SELECT n,nick FROM __CLSRC__ WHERE id_channel = ? ORDER BY n',[7],
            sub {push @rows,$_[0]{n}; $callback->(@_) if $callback},'content');
        1;
    };
    $error = $ok ? '' : $@;
    return ($status,\@rows,$error);
}
sub status_1412 { +{live_ok=>$_[0],sources=>$_[1],executed=>$_[2],ok_sources=>$_[3],rows=>$_[4],tainted=>$_[5]} }
for my $source ('CHANNEL_LOG','archive.CHANNEL_LOG_ARCHIVE') {
    for my $after (0,1) {
        for my $raise (0,1) {
            my ($bot,$db) = fixture_1412($raise,$source,$after);
            my ($g,$rows,$error) = gather_1412($bot,$db);
            my $live = $source eq 'CHANNEL_LOG';
            my @attempted = $live ? ('CHANNEL_LOG') : ('CHANNEL_LOG','archive.CHANNEL_LOG_ARCHIVE');
            my @expected_rows = $live ? ($after ? 10:()) : (10,20,($after ? 30:()));
            is_deeply([$error ? 'exception':'',$g,$rows,$db->{private_prepared},[sort keys %{$db->{private_finished}}]],
                ['',status_1412($live?0:($after?0:1),2,$live?1:2,$live?0:1,scalar(@expected_rows),!$live && $after?1:0),
                 \@expected_rows,\@attempted,[sort @attempted]],
                "$source after=$after RaiseError=$raise: fetch failure retains scoped rows, cleanup and live/tainted semantics");
            $db->disconnect;
        }
    }
}
# MB1206: failed execution still owns a statement requiring cleanup.
for my $source ('CHANNEL_LOG','archive.CHANNEL_LOG_ARCHIVE') {
    for my $raise (0,1) {
        for my $cleanup_failure (0,1) {
            my ($bot,$db) = fixture_1412($raise,undef,undef);
            $db->{private_execute_fault} = $source;
            $db->{private_cleanup_failure} = $cleanup_failure;
            my ($g,$rows,$error) = gather_1412($bot,$db);
            my $live = $source eq 'CHANNEL_LOG';
            my @attempted = $live ? ('CHANNEL_LOG') : ('CHANNEL_LOG','archive.CHANNEL_LOG_ARCHIVE');
            is_deeply([$error,$g,$rows,$db->{private_prepared},[sort keys %{$db->{private_finished}}]],
                ['',status_1412($live?0:1,2,$live?1:2,$live?0:1,$live?0:2,0),
                 $live?[]:[10,20],\@attempted,[sort @attempted]],
                "mb1206: $source execute failure cleans up and retains source policy (raise=$raise cleanup=$cleanup_failure)");
            like(join(' ',map {$_->[1]} @{$bot->{logger}{entries}}),qr/fixture history execute failure/,
                'mb1206: original execute diagnostic survives cleanup');
            $db->disconnect;
        }
    }
}
for my $empty (0,1) {
    my ($bot,$db) = fixture_1412(1,undef,undef,$empty);
    my ($g,$rows,$error) = gather_1412($bot,$db,undef,1);
    is_deeply([$error,$g,$rows], ['',status_1412(1,2,2,2,$empty?0:4,0),$empty?[]:[10,20,30,40]],
        $empty ? 'genuine empty live/archive reads remain successful' : 'direct Reader entry still merges both real sources and binds the requested channel');
    $db->disconnect;
}
{
    my ($bot,$db) = fixture_1412(1,undef,undef);
    $bot->{conf}{'mysql.CHANNEL_LOG_ARCHIVE_CONTENT_DAYS'} = 0;
    my ($g,$rows,$error) = gather_1412($bot,$db);
    is_deeply([$error,$g,$rows,$db->{private_prepared}], ['',status_1412(1,1,1,1,2,0),[10,20],['CHANNEL_LOG']],
        'existing content archive policy still excludes an ineligible archive');
    $db->disconnect;
}
for my $source ('CHANNEL_LOG','archive.CHANNEL_LOG_ARCHIVE') {
    for my $cleanup_failure (0,1) {
        my ($bot,$db) = fixture_1412(1,undef,undef);
        $db->{private_cleanup_failure} = $cleanup_failure;
        my ($g,$rows,$error) = gather_1412($bot,$db,sub {
            die "consumer callback failed\n" if $_[1] eq $source;
        });
        my @attempted = $source eq 'CHANNEL_LOG' ? ('CHANNEL_LOG')
            : ('CHANNEL_LOG','archive.CHANNEL_LOG_ARCHIVE');
        is_deeply([$g,$rows,$error,$db->{private_prepared},[sort keys %{$db->{private_finished}}]],
            [undef,$source eq 'CHANNEL_LOG' ? [10] : [10,20,30],"consumer callback failed\n",
             \@attempted,[sort @attempted]],
            "mb1205: $source consumer failure closes its statement and preserves the original exception (cleanup=$cleanup_failure)");
        $db->disconnect;
    }
}
for my $source ('CHANNEL_LOG','archive.CHANNEL_LOG_ARCHIVE') {
    my ($bot,$db) = fixture_1412(1,$source,1);
    @wire=();@audit=();
    my $ctx = Mediabot::Context->new(bot=>$bot,nick=>'Observer',channel=>'#test',command=>'wordcount',args=>['Alice']);
    $ctx->{_user_fetched}=1;
    my $ok = eval {$bot->command_registry->handler_for('wordcount','public')->($ctx);1};
    is_deeply([$ok?1:0,\@wire,scalar @audit], [1,[['notice','Observer','Database error.']],0],
        "$source: real wordcount refuses partial reads instead of escaping or publishing a total");
    $db->disconnect;
}
{
    my ($bot,$db) = fixture_1412(1,'archive.CHANNEL_LOG_ARCHIVE',1);
    $db->{private_cleanup_failure}=1;
    my ($g,$rows,$error) = gather_1412($bot,$db);
    is_deeply([$error,$g,$rows], ['',status_1412(0,2,2,1,3,1),[10,20,30]],
        'cleanup exceptions cannot hide the original partial-archive failure');
    $db->disconnect;
}
is_deeply(\@warnings,[],'native fetch, callback and cleanup paths are warning-free');
done_testing;
