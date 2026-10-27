use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use Mediabot::Mediabot;
use Mediabot::Context;
binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';

{
    package MB980::DBI; our @ISA = ('DBI');
    package MB980::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db,$sql,@rest) = @_;
        my $search = $sql =~ /q\.quotetext LIKE/;
        if ($search) {
            $db->{private_searches}++;
            $sql = 'SELECT * FROM mb980_missing_table'
                if ($db->{private_fault}//'') eq 'prepare';
        }
        my $sth = $db->SUPER::prepare($sql,@rest);
        $sth->{private_search} = $search ? 1 : 0 if $sth;
        return $sth;
    }
    package MB980::DBI::st; our @ISA = ('DBI::st');
    sub execute {
        my ($sth,@bind) = @_;
        if ($sth->{private_search}) {
            $sth->{private_fetched}=0;
            $sth->{Database}{private_bind}=\@bind;
            return $sth->set_err(1,'private search execution detail')
                if ($sth->{Database}{private_fault}//'') eq 'execute';
        }
        return $sth->SUPER::execute(@bind);
    }
    sub fetchrow_hashref {
        my ($sth) = @_;
        return $sth->SUPER::fetchrow_hashref unless $sth->{private_search};
        my $fault=$sth->{Database}{private_fault}//'';
        my $fetched=$sth->{private_fetched}++;
        return $sth->set_err(1,'private empty search failure') if $fault eq 'fetch_zero';
        die "private partial search exception\n" if $fault eq 'fetch_die' && $fetched;
        return $sth->set_err(1,'private partial search failure')
            if $fault eq 'fetch_partial' && $fetched;
        my $row=$sth->SUPER::fetchrow_hashref;
        die "private empty search exception\n" if !defined($row) && $fault eq 'fetch_die';
        return $sth->set_err(1,'private empty partial search failure')
            if !defined($row) && $fault eq 'fetch_partial';
        if ($fault eq 'row_error') {
            local $sth->{RaiseError}=0;
            $sth->set_err(1,'private unconfirmed search row');
        }
        return $row;
    }
    sub finish {
        my ($sth) = @_;
        my $search=$sth->{private_search};
        my $fault=$sth->{Database}{private_fault}//'';
        $sth->{Database}{private_finished}++ if $search;
        my $ok=$sth->SUPER::finish;
        # A caller must inspect errors before cleanup can clear their evidence.
        $sth->set_err(undef,undef);
        die "private search cleanup detail\n" if $search && $fault eq 'finish_die';
        return 0 if $search && $fault eq 'finish_false';
        return $ok;
    }
    package MB980::Log; sub log {push @{$_[0]{lines}},$_[2];1}
}
$INC{'MB980/DBI.pm'}=__FILE__;
my (@wire,@warnings,@logs);
no warnings qw(redefine once);
local *Mediabot::Quotes::botNotice=sub {push @wire,['notice',$_[1],$_[2]];1};
local *Mediabot::Quotes::botPrivmsg=sub {push @wire,['public',$_[1],$_[2]];1};
local *Mediabot::Quotes::logBot=sub {push @logs,[@_[1..$#_]];1};
local $SIG{__WARN__}=sub {push @warnings,@_};

sub setup_1356 {
    my ($raise,$fault) = @_;
    my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{
        RootClass=>'MB980::DBI',RaiseError=>$raise,PrintError=>0,sqlite_unicode=>1});
    $db->do('PRAGMA foreign_keys=ON');
    $db->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT)');
    $db->do('CREATE TABLE USER(id_user INTEGER PRIMARY KEY,nickname TEXT)');
    $db->do(q{CREATE TABLE QUOTES(id_quotes INTEGER PRIMARY KEY,
        id_channel INTEGER REFERENCES CHANNEL(id_channel),
        id_user INTEGER REFERENCES USER(id_user),quotetext TEXT,ts TEXT,hits INTEGER DEFAULT 0)});
    $db->do(q{INSERT INTO CHANNEL VALUES(1,'#test'),(2,'#other')});
    $db->do(q{INSERT INTO USER VALUES(7,'Alice'),(8,'Bob')});
    my $add=sub {$db->do(q{INSERT INTO QUOTES(id_quotes,id_channel,id_user,quotetext,ts)
        VALUES(?,?,?,?, '2026-10-27 12:00:00')},undef,@_)};
    $add->(1,1,7,'lumos lumos');
    $add->(2,1,8,'lumos');
    $add->(3,1,undef,'lumos lumos lumos');
    $add->(4,2,7,'lumos lumos lumos lumos');
    $add->(5,1,7,'literal 100% a_b wow! .*[ café 🦉');
    $add->(6,1,8,'literal 100X axb wow .a');
    $add->($_,1,7,'crowded') for 100..150;
    $add->($_,1,7,'many') for 200..210;
    $db->do('PRAGMA query_only=ON');
    $db->{private_fault}=$fault;$db->{private_searches}=0;$db->{private_finished}=0;
    my $bot=Mediabot->new({dbh=>$db});
    $bot->{logger}=bless {lines=>[]},'MB980::Log';
    return ($bot,$db);
}
sub invoke_1356 {
    my ($entry,$bot,@words) = @_;
    @wire=();@warnings=();@logs=();
    my $result;
    my $ok=eval {
        if ($entry =~ /^registry:(\w+):(\w+)$/) {
            my ($name,$sub)=($1,$2);
            my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Reader',channel=>'#test',
                command=>$name,args=>[$sub,@words]);
            $ctx->{_user_fetched}=1;
            $result=$bot->command_registry->handler_for($name,'public')->($ctx);
        } else {
            no strict 'refs';
            $result=&{"${entry}::mbQuoteSearch"}($bot,undef,'Reader','#test',@words);
        }
        1;
    };
    return ($ok?'':$@,$result);
}
sub texts_1356 {
    my $text=join("\n",map {$_->[2]} @wire);
    $text=~s/[\x02\x0f]//g;
    return $text;
}
my @entries=qw(Mediabot::Quotes Mediabot registry:q:search registry:q:s);
for my $entry (@entries) {
    for my $raise (0,1) {
        for my $fault (qw(prepare execute fetch_zero fetch_partial fetch_die row_error)) {
            for my $word (qw(lumos missing crowded)) {
                my ($bot,$db)=setup_1356($raise,$fault);
                my $label="$entry RaiseError=$raise $fault $word";
                my ($error,$result)=invoke_1356($entry,$bot,$word);
                is($error,'',"$label: failed search stays inside the command handler");
                is_deeply(\@wire,[['notice','Reader','Database error during search.']],
                    "$label: no partial results, false absence or refinement request");
                ok(!defined $result,"$label: failed search does not return a successful count");
                is($db->{private_searches},1,"$label: no automatic retry");
                is($db->{private_finished},$fault eq 'prepare'?0:1,
                    "$label: every allocated search cursor gets cleanup");
                is_deeply(\@logs,[],"$label: no successful command log");
                is(scalar @warnings,0,"$label: no warning escapes");
                unlike(join(' ',@{$bot->{logger}{lines}}),qr/private |mb980_missing_table/,
                    "$label: runtime logs omit raw driver details");
                is($db->selectrow_array('SELECT SUM(hits) FROM QUOTES'),0,
                    "$label: searches do not mutate recall counters");
                is($db->selectrow_array('SELECT COUNT(*) FROM QUOTES'),68,
                    "$label: read-only quote corpus stays intact");
                $db->{private_fault}='';
                ($error,$result)=invoke_1356($entry,$bot,$word);
                is($error,'',"$label: next explicit search recovers");
                is($db->{private_searches},2,"$label: only explicit recovery starts another search");
                my $expected=$word eq 'lumos'?3:$word eq 'crowded'?51:0;
                is($result,$expected,"$label: recovery returns the complete confirmed result size");
            }
        }
        for my $fault ('','finish_die','finish_false') {
            my ($bot,$db)=setup_1356($raise,$fault);
            my $label="$entry RaiseError=$raise '$fault'";
            for my $case (
                [['lumos'],3,qr/3 quote\(s\).* : 3\|1\|2\nBest match.*by Unknown.*id : 3/],
                [['lumos','lumos'],3,qr/3 quote\(s\).* : 3\|1\|2/],
                [['lumos','missing'],0,qr/No quote found matching "lumos missing" on #test/],
                [['crowded'],51,qr/More than 50 quotes/],
                [['many'],11,qr/11 quote\(s\).*210\|209\|208\|207\|206\|205\|204\|203\|202\|201 \.\.\./],
                (map {[[$_],1,qr/1 quote\(s\).* : 5\nBest match.*by Alice.*id : 5/]} ('100%','a_b','wow!','.*[','café','🦉')),
            ) {
                my ($words,$expected,$pattern)=@$case;
                my ($error,$count)=invoke_1356($entry,$bot,@$words);
                is($error,'',"$label @$words: confirmed read survives cleanup faults");
                is($count,$expected,"$label @$words: established result size");
                like(texts_1356(),$pattern,"$label @$words: ranking, literal matching and bounds retained");
                is(scalar @wire,$expected>0 && $expected<=50?2:1,"$label @$words: bounded public output");
                ok(!(grep {$_->[0] ne 'public' || $_->[1] ne '#test'} @wire),
                    "$label @$words: results stay in the requesting channel");
                is(scalar @logs,1,"$label @$words: confirmed search keeps its command log");
                is(scalar @warnings,0,"$label @$words: no warning escapes");
                is($db->{private_bind}[-1],51,"$label @$words: limit stays bound to 51");
            }
            my ($error)=invoke_1356($entry,$bot);
            is($error,'',"$label: missing text still shows syntax");
            is_deeply(\@wire,[['notice','Reader','q [search or s] <text> [word2 ...]']],
                "$label: syntax response stays private");
        }
    }
}
done_testing;
