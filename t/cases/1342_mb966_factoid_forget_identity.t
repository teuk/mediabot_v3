use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use File::Temp qw(tempdir);
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::User;
binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';

{
    package MB966::DBI; our @ISA = ('DBI');
    package MB966::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db,$sql,@rest) = @_;
        my $kind = $sql =~ /SELECT .*FROM FACTOID/s ? 'read'
            : $sql =~ /DELETE FROM FACTOID/ ? 'delete' : '';
        push @{$db->{private_mb966_queries}}, [$kind,$sql];
        my $actual = $sql;
        $actual = 'SELECT * FROM mb966_missing_table'
            if length($kind) && ($db->{private_mb966_fault}//'') eq "$kind.prepare";
        my $sth = $db->SUPER::prepare($actual,@rest);
        $sth->{private_mb966_kind} = $kind if $sth;
        return $sth;
    }
    package MB966::DBI::st; our @ISA = ('DBI::st');
    sub execute {
        my ($sth,@bind) = @_;
        my $db = $sth->{Database}; my $kind = $sth->{private_mb966_kind}//'';
        push @{$db->{private_mb966_binds}}, [$kind,@bind];
        if ($kind eq 'delete' && $db->{private_mb966_before_delete}) {
            my $cb = delete $db->{private_mb966_before_delete}; $cb->();
        }
        return $sth->set_err(1,'private factoid execute failure')
            if length($kind) && ($db->{private_mb966_fault}//'') eq "$kind.execute";
        return $sth->SUPER::execute(@bind);
    }
    sub fetchrow_hashref {
        my ($sth) = @_;
        return $sth->set_err(1,'private factoid fetch failure')
            if ($sth->{private_mb966_kind}//'') eq 'read'
                && ($sth->{Database}{private_mb966_fault}//'') eq 'read.fetch';
        return $sth->SUPER::fetchrow_hashref;
    }
    sub rows {
        my ($sth) = @_;
        return $sth->set_err(1,'private factoid row-count failure')
            if ($sth->{private_mb966_kind}//'') eq 'delete'
                && ($sth->{Database}{private_mb966_fault}//'') eq 'delete.rows';
        return $sth->SUPER::rows;
    }
    package MB966::Channel; sub get_id {7}
    package MB966::Log; sub log {1}
    package MB966::Metrics;
    sub inc { $_[0]{forgot}++ if $_[2]{op} eq 'forget'; 1 }
}
$INC{'MB966/DBI.pm'} = __FILE__;
my $tmp = tempdir(CLEANUP=>1);
my $serial = 0;
my (@wire,@warnings);
no warnings qw(redefine once);
local *Mediabot::UserCommands::botNotice = sub {push @wire,[@_[1,2]];1};
local $SIG{__WARN__} = sub {push @warnings,@_};

sub setup_1342 {
    my (%args) = @_;
    @wire=(); @warnings=();
    my $dsn = 'dbi:SQLite:dbname=' . $tmp . '/' . ++$serial . '.sqlite';
    my $db = DBI->connect($dsn,'','',{RootClass=>'MB966::DBI',RaiseError=>$args{raise},
        PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
    my $peer = DBI->connect($dsn,'','',{RaiseError=>1,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
    $db->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT)');
    $db->do(q{INSERT INTO CHANNEL VALUES(7,'#test'),(9,'#other')});
    $db->do('CREATE TABLE USER(id_user INTEGER PRIMARY KEY,nickname TEXT)');
    $db->do(q{INSERT INTO USER VALUES(7,'AuthorAccount'),(8,'OtherAccount'),(9,'OpAccount')});
    $db->do('CREATE TABLE USER_CHANNEL(id_channel INTEGER,id_user INTEGER,level INTEGER)');
    $db->do('INSERT INTO USER_CHANNEL VALUES(?,?,?)',undef,
        $args{op_channel}//7,$args{uid}//8,$args{level}//0);
    $db->do('CREATE TABLE CHANSET_LIST(id_chanset_list INTEGER,chanset TEXT)');
    $db->do(q{CREATE TABLE FACTOID(id_factoid INTEGER PRIMARY KEY AUTOINCREMENT,id_channel INTEGER,
        keyword TEXT,value TEXT,created_by INTEGER,created_by_nick TEXT,UNIQUE(id_channel,keyword))});
    $db->do(q{INSERT INTO FACTOID VALUES(10,7,'cafe','Un café',?,?)},undef,
        exists($args{author})?$args{author}:7,exists($args{author_nick})?$args{author_nick}:'OldNick');
    $db->do(q{INSERT INTO FACTOID VALUES(20,9,'cafe','Other channel',8,'OtherNick')});
    my $bot = bless {dbh=>$db,channels=>{'#test'=>bless({},'MB966::Channel')},
        metrics=>bless({forgot=>0},'MB966::Metrics'),logger=>bless({},'MB966::Log')},'Mediabot';
    my %account=(7=>'AuthorAccount',8=>'OtherAccount',9=>'OpAccount');
    my $user = defined($args{uid}) ? Mediabot::User->new({id_user=>$args{uid},
        nickname=>$account{$args{uid}},auth=>$args{auth}//0}) : undef;
    $db->{private_mb966_queries}=[]; $db->{private_mb966_binds}=[];
    return ($bot,$db,$peer,$user);
}
sub invoke_1342 {
    my ($entry,$bot,$user,$nick) = @_;
    my $ctx = Mediabot::Context->new(bot=>$bot,nick=>$nick,channel=>'#test',args=>['cafe']);
    $ctx->{user}=$user; $ctx->{_user_fetched}=1;
    no strict 'refs';
    my $ok = eval { &{ $entry . '::mbForget_ctx' }($ctx); 1 };
    return $ok ? '' : $@;
}
sub notices_1342 {join(' ',map {$_->[1]} @wire)}

my @cases = (
    {label=>'anonymous reuses the registered author nick',nick=>'OldNick',allow=>0},
    {label=>'another account reuses the author nick',nick=>'OldNick',uid=>8,auth=>1,allow=>0},
    {label=>'known author account is not logged in',nick=>'OldNick',uid=>7,auth=>0,allow=>0},
    {label=>'logged-in author has changed IRC nick',nick=>'NewNick',uid=>7,auth=>1,allow=>1},
    {label=>'logged-in author retains original nick',nick=>'OldNick',uid=>7,auth=>1,allow=>1},
    {label=>'operator account is not logged in',nick=>'Stranger',uid=>9,auth=>0,level=>400,allow=>0},
    {label=>'authenticated channel operator',nick=>'Stranger',uid=>9,auth=>1,level=>400,allow=>1},
    {label=>'authenticated level 399 is below operator',nick=>'Stranger',uid=>8,auth=>1,level=>399,allow=>0},
    {label=>'operator privilege belongs to another channel',nick=>'Stranger',uid=>9,auth=>1,level=>400,op_channel=>9,allow=>0},
    {label=>'legacy anonymous author keeps nickname ownership',nick=>'gUeSt',author=>undef,author_nick=>'Guest',allow=>1},
    {label=>'unrelated nick cannot delete an anonymous fact',nick=>'Stranger',author=>undef,author_nick=>'Guest',allow=>0},
    {label=>'invalid stored numeric author never falls back to nick',nick=>'OldNick',author=>0,allow=>0},
    {label=>'numeric author does not need a display nick',nick=>'NewNick',uid=>7,auth=>1,author_nick=>undef,allow=>1},
);
for my $entry (qw(Mediabot::CommunityState Mediabot::UserCommands Mediabot)) {
    # Full fault coverage belongs to the implementation; facades get wiring checks.
    my $domain = $entry eq 'Mediabot::CommunityState';
    for my $raise ($domain ? (0,1) : (1)) {
        for my $case ($domain ? @cases : @cases[0,3]) {
            next if $raise == 0; # Authorization cases do not depend on DBI error mode.
            my ($bot,$db,$peer,$user)=setup_1342(%$case,raise=>$raise);
            my $label="$entry RaiseError=$raise $case->{label}";
            is(invoke_1342($entry,$bot,$user,$case->{nick}),'',"$label: command contains exceptions");
            is($peer->selectrow_array('SELECT COUNT(*) FROM FACTOID WHERE id_factoid=10'),
                $case->{allow}?0:1,"$label: stored row follows identity authorization");
            is($bot->{metrics}{forgot},$case->{allow}?1:0,"$label: only a confirmed deletion increments the counter");
            my $notices=notices_1342();
            if ($case->{allow}) {like($notices,qr/Forgot 'cafe'/,"$label: confirmed deletion is acknowledged")}
            else {unlike($notices,qr/Forgot /,"$label: denied deletion has no false success")}
            is($peer->selectrow_array('SELECT value FROM FACTOID WHERE id_factoid=20'),
                'Other channel',"$label: other channel is preserved");
            is(scalar @warnings,0,"$label: no warning escapes");
        }

        for my $race ($domain && $raise == 1 ? qw(replace remove) : ()) {
            my ($bot,$db,$peer,$user)=setup_1342(raise=>$raise,uid=>7,auth=>1);
            $db->{private_mb966_before_delete}=sub {
                $peer->do('DELETE FROM FACTOID WHERE id_factoid=10');
                $peer->do(q{INSERT INTO FACTOID VALUES(77,7,'cafe','Replacement by someone else',8,'OtherNick')})
                    if $race eq 'replace';
            };
            my $label="$entry RaiseError=$raise $race after authorization";
            is(invoke_1342($entry,$bot,$user,'OldNick'),'',"$label: concurrent change is handled");
            is($peer->selectrow_array(q{SELECT COUNT(*) FROM FACTOID WHERE id_factoid=77}),
                $race eq 'replace'?1:0,"$label: replacement never inherits the old deletion permission");
            unlike(notices_1342(),qr/Forgot /,"$label: a zero-row delete has no false success");
            is($bot->{metrics}{forgot},0,"$label: stale delete does not increment success metrics");
            is(scalar @warnings,0,"$label: no warning escapes");
        }

        for my $fault ($domain ? qw(read.prepare read.execute read.fetch delete.prepare delete.execute delete.rows) : ('read.execute')) {
            my ($bot,$db,$peer,$user)=setup_1342(raise=>$raise,uid=>7,auth=>1);
            $db->{private_mb966_fault}=$fault;
            my $label="$entry RaiseError=$raise $fault";
            is(invoke_1342($entry,$bot,$user,'OldNick'),'',"$label: SQL failure stays inside the command");
            like(notices_1342(),qr/(?:lookup failed|could not confirm deletion)/,
                "$label: a failed lookup or write is reported as an error");
            unlike(notices_1342(),qr/Forgot |don't know|private factoid|mb966_missing/,
                "$label: no false success, false absence or raw exception");
            is($bot->{metrics}{forgot},0,"$label: no false success metric");
            is($peer->selectrow_array('SELECT COUNT(*) FROM FACTOID WHERE id_factoid=10'),
                $fault eq 'delete.rows'?0:1,"$label: fixture preserves data unless the actual deletion committed");
            is(scalar @warnings,0,"$label: no warning escapes");
        }

        {
            my ($bot,$db,$peer,$user)=setup_1342(raise=>$raise,uid=>7,auth=>1);
            $peer->do('DELETE FROM FACTOID WHERE id_factoid=10');
            is(invoke_1342($entry,$bot,$user,'OldNick'),'',"$entry: confirmed missing factoid is handled");
            like(notices_1342(),qr/don't know 'cafe'/,"$entry: legitimate absence remains distinct from read failure");
            is($bot->{metrics}{forgot},0,"$entry: absent factoid does not increment a deletion counter");
        }
    }
}
done_testing;
