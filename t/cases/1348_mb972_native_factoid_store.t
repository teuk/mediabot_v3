use strict;
use warnings;
use Test::More;
use DBI;
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::User;

{
    package MB972::DBI; our @ISA = ('DBI');
    package MB972::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db,$sql,@rest) = @_;
        my $store = $sql =~ /INSERT INTO FACTOID/;
        if ($store) {
            $db->{private_attempts}++;
            $sql =~ s/ON DUPLICATE KEY UPDATE\s+value = VALUES\(value\),\s+updated_at = CURRENT_TIMESTAMP/ON CONFLICT(id_channel,keyword) DO UPDATE SET value = excluded.value, updated_at = CURRENT_TIMESTAMP/;
            $sql = 'SELECT * FROM mb972_missing_table'
                if ($db->{private_fault}//'') eq 'prepare';
        }
        my $sth = $db->SUPER::prepare($sql,@rest);
        $sth->{private_store} = $store ? 1 : 0 if $sth;
        return $sth;
    }
    package MB972::DBI::st; our @ISA = ('DBI::st');
    sub execute {
        my ($sth,@bind) = @_;
        my $fault = $sth->{Database}{private_fault}//'';
        return $sth->set_err(1,'private store execution detail')
            if $sth->{private_store} && $fault eq 'execute';
        my $result = $sth->SUPER::execute(@bind);
        return $result unless $sth->{private_store};
        return $sth->set_err(1,'private lost store acknowledgement') if $fault eq 'after_commit';
        return '0E0' if $fault eq 'unchanged';
        return $result;
    }
    sub finish {
        my ($sth) = @_;
        $sth->{Database}{private_finished}++ if $sth->{private_store};
        my $ok = $sth->SUPER::finish;
        die "private store cleanup detail\n"
            if $sth->{private_store} && ($sth->{Database}{private_fault}//'') eq 'finish';
        return $ok;
    }
    package MB972::Channel; sub get_id {1}
    package MB972::Log; sub log {push @{$_[0]{lines}},$_[2];1}
    package MB972::Metrics; sub inc {$_[0]{learn}++;1}
    package MB972::Achievements;
    sub check_community_contributions {push @{$_[0]{calls}},[@_[1..3]];1}
}
$INC{'MB972/DBI.pm'} = __FILE__;
my (@wire,@warnings);
no warnings qw(redefine once);
local *Mediabot::UserCommands::botNotice = sub {push @wire,[$_[1],$_[2]];1};
local $SIG{__WARN__} = sub {push @warnings,@_};

sub setup_1348 {
    my ($raise,$fault) = @_;
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:','','',{
        RootClass=>'MB972::DBI',RaiseError=>$raise,PrintError=>0});
    $db->do('CREATE TABLE CHANSET_LIST(id_chanset_list INTEGER,chanset TEXT)');
    $db->do(q{CREATE TABLE FACTOID(id_factoid INTEGER PRIMARY KEY AUTOINCREMENT,
        id_channel INTEGER,keyword TEXT,value TEXT,created_by INTEGER,created_by_nick TEXT,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP,updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(id_channel,keyword))});
    $db->do(q{INSERT INTO FACTOID(id_channel,keyword,value,created_by,created_by_nick)
        VALUES(2,'spell','Other channel',8,'Other')});
    $db->{private_attempts}=0; $db->{private_finished}=0; $db->{private_fault}=$fault;
    my $bot = bless {dbh=>$db,channels=>{'#test'=>bless({},'MB972::Channel')},
        logger=>bless({lines=>[]},'MB972::Log'),metrics=>bless({learn=>0},'MB972::Metrics'),
        achievements=>bless({calls=>[]},'MB972::Achievements')},'Mediabot';
    return ($bot,$db);
}
sub invoke_1348 {
    my ($entry,$bot,$value) = @_;
    @wire=();@warnings=();
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Author_',channel=>'#test',
        args=>['spell','=',$value]);
    $ctx->{user}=Mediabot::User->new({id_user=>7,nickname=>'Author',auth=>1});
    $ctx->{_user_fetched}=1;
    no strict 'refs';
    my $ok=eval {&{"${entry}::mbLearn_ctx"}($ctx);1};
    return $ok?'':$@;
}
sub fact_1348 {
    $_[0]->selectrow_hashref(q{SELECT * FROM FACTOID WHERE id_channel=1 AND keyword='spell'});
}

for my $entry (qw(Mediabot::CommunityState Mediabot::UserCommands Mediabot)) {
    for my $raise (0,1) {
        for my $fault (qw(prepare execute after_commit)) {
            my ($bot,$db)=setup_1348($raise,$fault);
            my $label="$entry RaiseError=$raise $fault";
            is(invoke_1348($entry,$bot,'Original'),'',"$label: store error stays inside the handler");
            is_deeply(\@wire,[['Author_','learn: could not store the factoid.']],
                "$label: fixed failure notice without a false Learned confirmation");
            is($db->{private_attempts},1,"$label: no implicit retry of an uncertain write");
            is($db->{private_finished},$fault eq 'prepare'?0:1,
                "$label: any prepared store cursor is finished");
            is($bot->{metrics}{learn},0,"$label: no successful learn metric");
            is_deeply($bot->{achievements}{calls},[],"$label: unconfirmed store does not award contributions");
            is(scalar @warnings,0,"$label: no warning escapes");
            unlike(join(' ',@{$bot->{logger}{lines}}),qr/private (?:store|lost)/,
                "$label: driver details do not enter runtime logs");
            my $row=fact_1348($db);
            is(defined($row)?$row->{value}:undef,$fault eq 'after_commit'?'Original':undef,
                "$label: independent read distinguishes failure before and after commit");
            my $first_id=$row ? $row->{id_factoid}:undef;
            $db->{private_fault}='';
            is(invoke_1348($entry,$bot,'Recovered'),'',"$label: explicit retry can recover");
            like(join(' ',map {$_->[1]} @wire),qr/Learned 'spell'/,
                "$label: recovery acknowledges only the confirmed store");
            $row=fact_1348($db) || {};
            is($row->{value},'Recovered',"$label: recovery actually persists the requested value");
            is($row->{created_by},7,"$label: existing authenticated author attribution is retained");
            is($row->{id_factoid},$first_id,"$label: a committed first attempt is updated in place")
                if defined $first_id;
            is($db->selectrow_array('SELECT COUNT(*) FROM FACTOID'),2,
                "$label: retries create no duplicate and preserve another channel");
            is($db->selectrow_array('SELECT value FROM FACTOID WHERE id_channel=2'),'Other channel',
                "$label: other-channel data stays intact");
            is($bot->{metrics}{learn},1,"$label: only recovery contributes to the success metric");
            is_deeply($bot->{achievements}{calls},[['Author_','#test',7]],
                "$label: only the confirmed recovery invokes contribution accounting");
        }
        for my $fault ('','unchanged','finish') {
            my ($bot,$db)=setup_1348($raise,'');
            is(invoke_1348($entry,$bot,'Original'),'',"$entry: healthy initial store succeeds");
            my $first=fact_1348($db);
            $db->{private_fault}=$fault;
            my $label="$entry RaiseError=$raise repeated store '$fault'";
            is(invoke_1348($entry,$bot,'Original'),'',"$label: confirmed execute survives cursor cleanup errors");
            is_deeply(\@wire,[['Author_',"Learned 'spell' for #test."]],
                "$label: unchanged or confirmed store keeps the normal confirmation");
            my $next=fact_1348($db);
            is($next->{id_factoid},$first->{id_factoid},"$label: UPSERT retains row identity");
            is($next->{value},'Original',"$label: acknowledged data really exists");
            is($next->{created_by_nick},'Author_',"$label: original display attribution is retained");
            is($db->{private_attempts},2,"$label: one attempt per explicit command");
            is($db->{private_finished},2,"$label: both store cursors get cleanup attempts");
            is($bot->{metrics}{learn},2,"$label: each confirmed command contributes once");
            is(scalar @{$bot->{achievements}{calls}},2,"$label: accounting runs once per confirmed command");
        }
    }
}
done_testing;
