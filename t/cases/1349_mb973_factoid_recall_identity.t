use strict;
use warnings;
use Test::More;
use DBI;
use File::Temp qw(tempdir);
use Mediabot::Mediabot;
use Mediabot::Context;

{
    package MB973::DBI; our @ISA = ('DBI');
    package MB973::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db,$sql,@rest) = @_;
        my $update = $sql =~ /UPDATE FACTOID/;
        if ($update) {
            $db->{private_updates}++;
            if ($db->{private_before_update}) {
                my $cb=delete $db->{private_before_update}; $cb->();
            }
        }
        my $sth=$db->SUPER::prepare($update && ($db->{private_fault}//'') eq 'prepare'
            ? 'SELECT * FROM mb973_missing_table' : $sql,@rest);
        $sth->{private_update}=$update ? 1 : 0 if $sth;
        return $sth;
    }
    package MB973::DBI::st; our @ISA = ('DBI::st');
    sub execute {
        my ($sth,@bind)=@_;
        return $sth->set_err(1,'private recall update detail')
            if $sth->{private_update} && ($sth->{Database}{private_fault}//'') eq 'execute';
        return $sth->SUPER::execute(@bind);
    }
    sub fetchrow_hashref {
        my ($sth)=@_;
        my $row=$sth->SUPER::fetchrow_hashref;
        $row->{id_factoid}=$sth->{Database}{private_bad_id}
            if $row && $sth->{Statement}=~/FROM FACTOID/
                && $sth->{Database}{private_bad_id_enabled};
        return $row;
    }
    sub finish {
        my ($sth)=@_;
        $sth->{Database}{private_finished}++ if $sth->{private_update};
        my $ok=$sth->SUPER::finish;
        die "private recall cleanup detail\n"
            if $sth->{private_update} && ($sth->{Database}{private_fault}//'') eq 'finish';
        return $ok;
    }
    package MB973::Channel; sub get_id {1}
    package MB973::Log; sub log {1}
    package MB973::Metrics; sub inc {$_[0]{recalls}++;1}
}
$INC{'MB973/DBI.pm'}=__FILE__;
my $tmp=tempdir(CLEANUP=>1);
my $serial=0;
my (@wire,@warnings);
no warnings qw(redefine once);
local *Mediabot::UserCommands::botNotice=sub {push @wire,['notice',$_[1],$_[2]];1};
local *Mediabot::UserCommands::botPrivmsg=sub {push @wire,['public',$_[1],$_[2]];1};
local $SIG{__WARN__}=sub {push @warnings,@_};

sub setup_1349 {
    my ($raise,$fault)=@_;
    my $dsn='dbi:SQLite:dbname='.$tmp.'/'.++$serial.'.sqlite';
    my $db=DBI->connect($dsn,'','',{RootClass=>'MB973::DBI',RaiseError=>$raise,PrintError=>0,AutoCommit=>1});
    my $peer=DBI->connect($dsn,'','',{RaiseError=>1,PrintError=>0,AutoCommit=>1});
    $peer->do('CREATE TABLE CHANSET_LIST(id_chanset_list INTEGER,chanset TEXT)');
    $peer->do(q{CREATE TABLE FACTOID(id_factoid INTEGER PRIMARY KEY AUTOINCREMENT,
        id_channel INTEGER,keyword TEXT,value TEXT,created_by_nick TEXT,hits INTEGER,
        UNIQUE(id_channel,keyword))});
    $peer->do(q{INSERT INTO FACTOID VALUES
        (10,1,'spell','Original text','Author',3),
        (20,2,'spell','Other channel','Other',50)});
    $db->{private_fault}=$fault; $db->{private_updates}=0; $db->{private_finished}=0;
    my $bot=bless {dbh=>$db,channels=>{'#test'=>bless({},'MB973::Channel')},
        logger=>bless({},'MB973::Log'),metrics=>bless({recalls=>0},'MB973::Metrics')},'Mediabot';
    return ($bot,$db,$peer);
}
sub invoke_1349 {
    my ($entry,$bot,$quiet)=@_;
    @wire=(); @warnings=();
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Reader',channel=>'#test',
        args=>$quiet?['__quiet__','spell']:['spell']);
    no strict 'refs';
    my $ok=eval {&{"${entry}::mbWhatis_ctx"}($ctx);1};
    return $ok?'':$@;
}
for my $entry (qw(Mediabot::CommunityState Mediabot::UserCommands Mediabot)) {
    # Full fault coverage belongs to the implementation; facades get wiring checks.
    my $domain = $entry eq 'Mediabot::CommunityState';
    for my $raise ($domain ? (0,1) : (1)) {
        for my $quiet ($domain ? (0,1) : (0)) {
            for my $race ($domain ? qw(none remove replace move) : ('none')) {
                my ($bot,$db,$peer)=setup_1349($raise,'');
                $db->{private_before_update}=sub {
                    if ($race eq 'move') {
                        $peer->do(q{UPDATE FACTOID SET id_channel=2,keyword='moved' WHERE id_factoid=10});
                    } else {
                        $peer->do('DELETE FROM FACTOID WHERE id_factoid=10');
                        $peer->do(q{INSERT INTO FACTOID VALUES(11,1,'spell','Replacement text','NewAuthor',7)})
                            if $race eq 'replace';
                    }
                } if $race ne 'none';
                my $label="$entry RaiseError=$raise quiet=$quiet $race";
                is(invoke_1349($entry,$bot,$quiet),'',"$label: recall completes despite concurrent change");
                is_deeply(\@wire,[['public','#test','spell: Original text']],
                    "$label: confirmed original text is still sent exactly once");
                is($peer->selectrow_array('SELECT hits FROM FACTOID WHERE id_factoid=11'),
                    $race eq 'replace'?7:undef,"$label: replacement receives no recall for the old fact");
                is($peer->selectrow_array('SELECT hits FROM FACTOID WHERE id_factoid=10'),
                    $race eq 'none'?4:$race eq 'move'?3:undef,
                    "$label: only the original row in the original channel is incremented");
                is($peer->selectrow_array('SELECT hits FROM FACTOID WHERE id_factoid=20'),50,
                    "$label: same keyword in another channel is untouched");
                is($db->{private_updates},1,"$label: no fallback or implicit retry by keyword");
                is($bot->{metrics}{recalls},1,"$label: confirmed public recall metric is retained");
                is(scalar @warnings,0,"$label: no warning escapes");
            }
        }
    }
}
for my $raise (0,1) {
    for my $quiet (0,1) {
        for my $fault (qw(prepare execute finish)) {
            my ($bot,$db,$peer)=setup_1349($raise,$fault);
            my $label="counter $fault RaiseError=$raise quiet=$quiet";
            is(invoke_1349('Mediabot',$bot,$quiet),'',"$label: counter error remains non-fatal");
            is_deeply(\@wire,[['public','#test','spell: Original text']],
                "$label: counter failure does not hide a confirmed read");
            is($db->{private_finished},$fault eq 'prepare'?0:1,
                "$label: prepared counter cursor gets a cleanup attempt");
            is($peer->selectrow_array('SELECT hits FROM FACTOID WHERE id_factoid=10'),
                $fault eq 'finish'?4:3,"$label: actual data shows whether the increment ran");
            is($db->{private_updates},1,"$label: no implicit retry after an uncertain update");
            is($bot->{metrics}{recalls},1,"$label: display metric is independent of best-effort SQL accounting");
            is(scalar @warnings,0,"$label: no warning escapes");
        }
        for my $bad_id (undef,0,'invalid') {
            my ($bot,$db,$peer)=setup_1349($raise,'');
            $db->{private_bad_id_enabled}=1;
            $db->{private_bad_id}=$bad_id;
            is(invoke_1349('Mediabot',$bot,$quiet),'','unavailable identity does not prevent confirmed text display');
            is_deeply(\@wire,[['public','#test','spell: Original text']],
                'read remains usable when the optional counter cannot be scoped');
            is($db->{private_updates},0,'invalid identity never falls back to a keyword update');
            is($peer->selectrow_array('SELECT hits FROM FACTOID WHERE id_factoid=10'),3,
                'invalid identity does not modify the stored counter');
        }
    }
}
done_testing;
