use strict;
use warnings;
use Test::More;
use DBI;
use File::Temp qw(tempdir);
use String::IRC;
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::User;

{
    package MB974::DBI; our @ISA = ('DBI');
    package MB974::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db,$sql,@rest) = @_;
        my $probe = $sql =~ /SELECT QUOTES\.id_quotes FROM QUOTES JOIN CHANNEL/;
        if ($probe) {
            $db->{private_probes}++;
            return $db->set_err(1,'private duplicate prepare detail')
                if ($db->{private_fault}//'') eq 'prepare';
        }
        $db->{private_inserts}++ if $sql =~ /INSERT INTO QUOTES/;
        my $sth = $db->SUPER::prepare($sql,@rest);
        $sth->{private_probe} = $probe ? 1 : 0 if $sth;
        return $sth;
    }
    package MB974::DBI::st; our @ISA = ('DBI::st');
    sub execute {
        my ($sth,@bind) = @_;
        return $sth->set_err(1,'private duplicate execute detail')
            if $sth->{private_probe} && ($sth->{Database}{private_fault}//'') eq 'execute';
        return $sth->SUPER::execute(@bind);
    }
    sub fetchrow_hashref {
        my ($sth) = @_;
        my $fault = $sth->{Database}{private_fault}//'';
        if ($sth->{private_probe}) {
            die "private duplicate fetch exception\n" if $fault eq 'fetch_die';
            return $sth->set_err(1,'private duplicate fetch detail') if $fault eq 'fetch';
        }
        my $row = $sth->SUPER::fetchrow_hashref;
        # Even a returned row is not reliable if the driver reports an error.
        $sth->set_err(1,'private duplicate row detail')
            if $sth->{private_probe} && $fault eq 'row_error';
        return $row;
    }
    sub finish {
        my ($sth) = @_;
        my $fault = $sth->{Database}{private_fault}//'';
        $sth->{Database}{private_finished}++ if $sth->{private_probe};
        my $ok = $sth->SUPER::finish;
        # Cleanup can clear the status: the caller must inspect it beforehand.
        $sth->set_err(undef,undef);
        die "private duplicate cleanup detail\n"
            if $sth->{private_probe} && $fault eq 'finish_die';
        return 0 if $sth->{private_probe} && $fault eq 'finish_false';
        return $ok;
    }
    package MB974::Channel; sub get_id {1}
    package MB974::Log; sub log {push @{$_[0]{lines}},$_[2];1}
    package MB974::Achievements;
    sub check_community_contributions {push @{$_[0]{calls}},[@_[1..3]];1}
}
$INC{'MB974/DBI.pm'} = __FILE__;
my $tmp = tempdir(CLEANUP=>1);
my $serial = 0;
my (@wire,@warnings,@command_logs);
no warnings qw(redefine once);
local *Mediabot::Quotes::botNotice = sub {push @wire,['notice',$_[1],$_[2]];1};
local *Mediabot::Quotes::botPrivmsg = sub {push @wire,['public',$_[1],$_[2]];1};
local *Mediabot::Quotes::logBot = sub {push @command_logs,[@_[1..$#_]];1};
local $SIG{__WARN__} = sub {push @warnings,@_};

sub setup_1350 {
    my ($raise,$fault) = @_;
    my $dsn = 'dbi:SQLite:dbname='.$tmp.'/'.++$serial.'.sqlite';
    my $db = DBI->connect($dsn,'','',{
        RootClass=>'MB974::DBI',RaiseError=>$raise,PrintError=>0,AutoCommit=>1});
    my $peer = DBI->connect($dsn,'','',{RaiseError=>1,PrintError=>0,AutoCommit=>1});
    $peer->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT)');
    $peer->do(q{CREATE TABLE QUOTES(id_quotes INTEGER PRIMARY KEY AUTOINCREMENT,
        id_channel INTEGER,id_user INTEGER,quotetext TEXT)});
    $peer->do(q{INSERT INTO CHANNEL VALUES(1,'#test'),(2,'#other')});
    $peer->do(q{INSERT INTO QUOTES VALUES
        (10,1,7,'Existing quote'),(20,2,8,'Other channel quote')});
    $db->{private_fault}=$fault; $db->{private_probes}=0;
    $db->{private_finished}=0; $db->{private_inserts}=0;
    my $bot = bless {dbh=>$db,channels=>{'#test'=>bless({},'MB974::Channel')},
        logger=>bless({lines=>[]},'MB974::Log'),
        achievements=>bless({calls=>[]},'MB974::Achievements')},'Mediabot';
    return ($bot,$db,$peer);
}
sub invoke_1350 {
    my ($entry,$bot,$text,$auth) = @_;
    @wire=(); @warnings=(); @command_logs=();
    my $result;
    my $ok = eval {
        if ($entry =~ /^context:(.+)$/) {
            my $ctx = Mediabot::Context->new(bot=>$bot,nick=>'Speaker',channel=>'#test',
                args=>[$1,$text]);
            $ctx->{user}=Mediabot::User->new({id_user=>7,nickname=>'Account',auth=>$auth});
            $ctx->{user}{level}='User'; $ctx->{user}{level_desc}='User';
            $ctx->{_user_fetched}=1;
            $result=Mediabot::mbQuotes_ctx($ctx);
        } else {
            no strict 'refs';
            $result=&{"${entry}::mbQuoteAdd"}($bot,undef,$auth?7:undef,
                $auth?'Account':undef,'Speaker','#test',$text);
        }
        1;
    };
    return ($ok?'':$@,$result);
}
my @entries = qw(Mediabot::Quotes Mediabot context:add context:a);
for my $entry (@entries) {
    # Full fault coverage belongs to the implementation; facades get wiring checks.
    my $domain = $entry eq 'Mediabot::Quotes';
    for my $raise ($domain ? (0,1) : (1)) {
        for my $fault ($domain ? qw(prepare execute fetch fetch_die row_error) : ('execute')) {
            for my $text ($domain && $fault =~ /fetch|row_error/
                    ? ('Existing quote','New quote') : ('New quote')) {
                my ($bot,$db,$peer)=setup_1350($raise,$fault);
                my $label="$entry RaiseError=$raise $fault '$text'";
                my ($error)=invoke_1350($entry,$bot,$text,1);
                is($error,'',"$label: probe failure stays inside the handler");
                is_deeply(\@wire,[['notice','Speaker','Database error while checking quote.']],
                    "$label: one fixed database error, no false duplicate or addition");
                is($db->{private_inserts},0,"$label: unconfirmed absence never reaches INSERT");
                is($db->{private_probes},1,"$label: no implicit retry");
                is($db->{private_finished},$fault eq 'prepare'?0:1,
                    "$label: every allocated probe cursor gets a cleanup attempt");
                is($peer->selectrow_array('SELECT COUNT(*) FROM QUOTES'),2,
                    "$label: independent connection observes no extra quote");
                is_deeply($bot->{achievements}{calls},[],"$label: no contribution for an unconfirmed add");
                is_deeply(\@command_logs,[],"$label: no successful command log");
                is(scalar @warnings,0,"$label: no warning escapes");
                unlike(join(' ',@{$bot->{logger}{lines}}),qr/private duplicate/,
                    "$label: runtime logs omit driver details");
            }
        }
    }
}

# A cleanup failure cannot invalidate a completed lookup or trigger another read.
for my $entry (@entries) {
    # Full fault coverage belongs to the implementation; facades get wiring checks.
    my $domain = $entry eq 'Mediabot::Quotes';
    for my $raise (1) {
        for my $fault ($domain ? ('','finish_die','finish_false') : ('')) {
            for my $auth ($domain ? (0,1) : (1)) {
                my ($bot,$db,$peer)=setup_1350($raise,$fault);
                my $label="$entry RaiseError=$raise '$fault' auth=$auth";
                my ($error)=invoke_1350($entry,$bot,'Existing quote',$auth);
                is($error,'',"$label: confirmed duplicate survives cleanup faults");
                is_deeply(\@wire,[['public','#test','Quote (id: 10) already exists']],
                    "$label: established duplicate response is preserved");
                is($db->{private_inserts},0,"$label: genuine duplicate is never inserted");
                is_deeply($bot->{achievements}{calls},[],"$label: duplicate awards no contribution");
                is($db->{private_finished},1,"$label: duplicate cursor cleanup is attempted once");
                ($error,my $id)=invoke_1350($entry,$bot,'Other channel quote',$auth);
                is($error,'',"$label: another channel's text can still be added here");
                my $row=$peer->selectrow_hashref(q{SELECT * FROM QUOTES
                    WHERE id_channel=1 AND quotetext='Other channel quote'});
                ok($row && $row->{id_quotes}>20,"$label: independent connection sees the real insert");
                is($id,$row?$row->{id_quotes}:undef,"$label: returned id is the actual inserted quote");
                is($row?$row->{id_user}:undef,$auth?7:undef,"$label: account/anonymous attribution is preserved");
                is_deeply($bot->{achievements}{calls},[['Speaker','#test',$auth?7:undef]],
                    "$label: exactly one contribution for the confirmed insert");
                is($db->{private_inserts},1,"$label: one insert for the explicit new quote");
                is($peer->selectrow_array('SELECT quotetext FROM QUOTES WHERE id_quotes=20'),
                    'Other channel quote',"$label: original quote in the other channel is intact");
                like(join(' ',map {$_->[2]} @wire),qr/done\. \(id:/,
                    "$label: normal public addition confirmation is preserved");
                is(scalar @warnings,0,"$label: healthy path emits no warning");
            }
        }
    }
}

for my $raise (0,1) {
    my ($bot,$db,$peer)=setup_1350($raise,'fetch');
    invoke_1350('context:add',$bot,'New quote',1);
    $db->{private_fault}='';
    my ($error,$id)=invoke_1350('context:add',$bot,'New quote',1);
    is($error,'',"RaiseError=$raise: next explicit command recovers after a failed probe");
    is($peer->selectrow_array(q{SELECT COUNT(*) FROM QUOTES WHERE quotetext='New quote'}),1,
        "RaiseError=$raise: explicit recovery persists one new quote");
    is($db->{private_probes},2,"RaiseError=$raise: one probe per explicit command");
    is($db->{private_finished},2,"RaiseError=$raise: failed and successful cursors are both finished");
}
done_testing;
