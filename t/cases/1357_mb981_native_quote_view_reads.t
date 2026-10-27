use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use File::Temp qw(tempdir);
use Mediabot::Mediabot;
use Mediabot::Context;

binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
{
    package MB981::DBI; our @ISA = ('DBI');
    package MB981::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db,$sql,@rest) = @_;
        my $view=$sql =~ /SELECT QUOTES\.id_quotes, QUOTES\.quotetext/;
        my $bump=$sql =~ /UPDATE QUOTES SET hits/;
        if ($view) {
            $db->{private_reads}++;
            $sql='SELECT * FROM mb981_missing_table' if ($db->{private_fault}//'') eq 'prepare';
        }
        $db->{private_bumps}++ if $bump;
        my $sth=$db->SUPER::prepare($sql,@rest);
        if ($sth) {$sth->{private_view}=$view?1:0;$sth->{private_bump}=$bump?1:0}
        return $sth;
    }
    package MB981::DBI::st; our @ISA = ('DBI::st');
    sub execute {
        my ($sth,@bind) = @_;
        my $fault=$sth->{Database}{private_fault}//'';
        return $sth->set_err(1,'private view execution detail')
            if $sth->{private_view} && $fault eq 'execute';
        return $sth->set_err(1,'private optional counter detail')
            if $sth->{private_bump} && $fault eq 'counter_error';
        return $sth->SUPER::execute(@bind);
    }
    sub fetchrow_hashref {
        my ($sth) = @_;
        my $fault=$sth->{Database}{private_fault}//'';
        if ($sth->{private_view}) {
            return $sth->set_err(1,'private missing view read') if $fault eq 'fetch';
            die "private view fetch exception\n" if $fault eq 'fetch_die';
        }
        my $row=$sth->SUPER::fetchrow_hashref;
        if ($sth->{private_view} && $fault eq 'row_error') {
            local $sth->{RaiseError}=0;
            $sth->set_err(1,'private unconfirmed view row');
        }
        return $row;
    }
    sub finish {
        my ($sth) = @_;
        my $view=$sth->{private_view};
        my $fault=$sth->{Database}{private_fault}//'';
        $sth->{Database}{private_finished}++ if $view;
        my $ok=$sth->SUPER::finish;
        $sth->set_err(undef,undef);
        die "private view cleanup detail\n" if $view && $fault eq 'finish_die';
        return 0 if $view && $fault eq 'finish_false';
        return $ok;
    }
    package MB981::Log; sub log {push @{$_[0]{lines}},$_[2];1}
}
$INC{'MB981/DBI.pm'}=__FILE__;
my $tmp=tempdir(CLEANUP=>1);
my $serial=0;
my (@wire,@logs,@warnings);
no warnings qw(redefine once);
local *Mediabot::Quotes::botNotice=sub {push @wire,['notice',$_[1],$_[2]];1};
local *Mediabot::Quotes::botPrivmsg=sub {push @wire,['public',$_[1],$_[2]];1};
local *Mediabot::Quotes::logBot=sub {push @logs,[@_[1..$#_]];1};
local $SIG{__WARN__}=sub {push @warnings,@_};

sub setup_1357 {
    my ($raise,$fault)=@_;
    my $dsn='dbi:SQLite:dbname='.$tmp.'/'.++$serial.'.sqlite';
    my $db=DBI->connect($dsn,'','',{RootClass=>'MB981::DBI',
        RaiseError=>$raise,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
    my $peer=DBI->connect($dsn,'','',{RaiseError=>1,PrintError=>0,
        AutoCommit=>1,sqlite_unicode=>1});
    $db->do('PRAGMA foreign_keys=ON');$peer->do('PRAGMA foreign_keys=ON');
    $peer->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT)');
    $peer->do('CREATE TABLE USER(id_user INTEGER PRIMARY KEY,nickname TEXT)');
    $peer->do(q{CREATE TABLE QUOTES(id_quotes INTEGER PRIMARY KEY,
        id_channel INTEGER REFERENCES CHANNEL(id_channel),
        id_user INTEGER REFERENCES USER(id_user),quotetext TEXT,hits INTEGER)});
    $peer->do(q{INSERT INTO CHANNEL VALUES(1,'#test'),(2,'#other')});
    $peer->do(q{INSERT INTO USER VALUES(7,'Alice'),(8,'Bob')});
    $peer->do(q{INSERT INTO QUOTES VALUES(1,1,7,?,5),(2,1,NULL,'Anonymous quote',2),
        (20,2,8,'Foreign quote',7)},undef,'Un été à Poudlard 🦉 'x30);
    $db->{private_fault}=$fault;
    for (qw(reads bumps finished)) {$db->{'private_'.$_}=0}
    my $bot=Mediabot->new({dbh=>$db});
    $bot->{logger}=bless {lines=>[]},'MB981::Log';
    $bot->{_quote_last_rand}{'#test'}=20;
    return ($bot,$db,$peer);
}
sub invoke_1357 {
    my ($entry,$bot,$id)=@_;
    @wire=();@logs=();@warnings=();
    my $result;
    my $ok=eval {
        if ($entry =~ /^registry:q:(\w+)$/) {
            my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Reader',channel=>'#test',
                command=>'q',args=>[$1,$id]);
            $ctx->{_user_fetched}=1;
            $result=$bot->command_registry->handler_for('q','public')->($ctx);
        } else {
            no strict 'refs';
            $result=&{"${entry}::mbQuoteView"}($bot,undef,'Reader','#test',$id);
        }
        1;
    };
    return ($ok?'':$@,$result);
}
my @entries=qw(Mediabot::Quotes Mediabot registry:q:view registry:q:v);
for my $entry (@entries) {
    for my $raise (0,1) {
        for my $fault (qw(prepare execute fetch fetch_die row_error)) {
            for my $id (1,20,999) {
                my ($bot,$db,$peer)=setup_1357($raise,$fault);
                my $label="$entry RaiseError=$raise $fault id=$id";
                my ($error,$result)=invoke_1357($entry,$bot,$id);
                is($error,'',"$label: failed read stays inside the handler");
                is_deeply(\@wire,[['notice','Reader','Database error while reading quote.']],
                    "$label: no false absence or unconfirmed public quote");
                ok(!defined $result,"$label: unconfirmed read is not a successful view");
                is($db->{private_reads},1,"$label: no automatic retry");
                is($db->{private_finished},$fault eq 'prepare'?0:1,"$label: allocated reader cleaned once");
                is($db->{private_bumps},0,"$label: no recall attempted for an unconfirmed read");
                is($peer->selectrow_array('SELECT SUM(hits) FROM QUOTES'),14,
                    "$label: independent observer sees no false recall");
                is_deeply(\@logs,[],"$label: no successful command log");
                is(scalar @warnings,0,"$label: no warning escapes");
                unlike(join(' ',@{$bot->{logger}{lines}}),qr/private |mb981_missing_table/,
                    "$label: no raw driver details in runtime logs");
                is($bot->{_quote_last_rand}{'#test'},20,"$label: random quote memory is preserved");
                $db->{private_fault}='';
                ($error,$result)=invoke_1357($entry,$bot,$id);
                is($error,'',"$label: next explicit command recovers");
                is($result,1,"$label: normal view/absence return value is retained");
                is($peer->selectrow_array('SELECT SUM(hits) FROM QUOTES'),$id==1?15:14,
                    "$label: recovery counts only a confirmed local quote");
                is($db->{private_reads},2,"$label: only explicit recovery repeats the read");
            }
        }
        for my $fault ('','finish_die','finish_false','counter_error') {
            for my $id (1,2,20,999) {
                my ($bot,$db,$peer)=setup_1357($raise,$fault);
                my $label="$entry RaiseError=$raise '$fault' id=$id";
                my ($error,$result)=invoke_1357($entry,$bot,$id);
                is($error,'',"$label: confirmed read survives cleanup or optional recall failure");
                is($result,1,"$label: normal return value retained");
                is(scalar @wire,1,"$label: exactly one public response");
                is_deeply([@{$wire[0]//[]}[0,1]],['public','#test'],"$label: response stays scoped");
                my $visible=$wire[0][2]//'';$visible=~s/[\x02\x0f]//g;
                if ($id==1) {
                    like($visible,qr/^\(Alice\) \[id: 1\] Un été à Poudlard 🦉 .*\.\.\.$/,
                        "$label: real author and Unicode excerpt retained");
                } elsif ($id==2) {
                    is($visible,'(Unknown) [id: 2] Anonymous quote',"$label: anonymous attribution retained");
                } else {
                    is($visible,"Quote (id : $id) does not exist for channel #test",
                        "$label: genuine absence excludes other channels");
                }
                is($db->{private_finished},1,"$label: reader cleaned once before further work");
                my $found=$id==1 || $id==2;
                is($db->{private_bumps},$found?1:0,"$label: recall attempted only for an actual displayed quote");
                is($peer->selectrow_array('SELECT SUM(hits) FROM QUOTES'),
                    $found && $fault ne 'counter_error'?15:14,"$label: actual recall remains best-effort");
                is($peer->selectrow_array('SELECT hits FROM QUOTES WHERE id_quotes=20'),7,
                    "$label: foreign-channel counter stays untouched");
                is(scalar @logs,$found?1:0,"$label: established command logging retained");
                is(scalar @warnings,0,"$label: no warning escapes");
                is($bot->{_quote_last_rand}{'#test'},20,"$label: view does not replace random memory");
            }
        }
    }
}
done_testing;
