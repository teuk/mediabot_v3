use strict;
use warnings;
use Test::More;
use DBI;
use Mediabot::Mediabot;
use Mediabot::Context;

{
    package MB976::DBI; our @ISA=('DBI');
    package MB976::DBI::db; our @ISA=('DBI::db');
    sub prepare {
        my ($db,$sql,@rest)=@_;
        if ($db->{private_ready}) {
            die 'count commands must remain read-only' unless $sql =~ /^\s*SELECT\b/i;
            $db->{private_queries}++;
            return $db->set_err(1,'private count prepare detail')
                if ($db->{private_fault}//'') eq 'prepare';
        }
        return $db->SUPER::prepare($sql,@rest);
    }
    package MB976::DBI::st; our @ISA=('DBI::st');
    sub execute {
        my ($sth,@bind)=@_;
        return $sth->set_err(1,'private count execute detail')
            if ($sth->{Database}{private_fault}//'') eq 'execute';
        return $sth->SUPER::execute(@bind);
    }
    sub fetchrow_hashref {
        my ($sth)=@_;
        my $fault=$sth->{Database}{private_fault}//'';
        return $sth->set_err(1,'private count fetch detail') if $fault eq 'fetch';
        die "private count fetch exception\n" if $fault eq 'fetch_die';
        return undef if $fault eq 'no_row';
        my $row=$sth->SUPER::fetchrow_hashref;
        $sth->set_err(1,'private count row detail') if $fault eq 'row_error';
        $row->{cnt}=undef if $row && $fault eq 'missing_count';
        return $row;
    }
    sub finish {
        my ($sth)=@_;
        $sth->{Database}{private_finished}++;
        my $ok=$sth->SUPER::finish;
        # A driver can clear the error on cleanup; check it before this call.
        $sth->set_err(undef,undef);
        die "private count cleanup detail\n"
            if ($sth->{Database}{private_fault}//'') eq 'finish';
        return $ok;
    }
    package MB976::Log; sub log {push @{$_[0]{lines}},$_[2];1}
}
$INC{'MB976/DBI.pm'}=__FILE__;
my (@wire,@warnings);
no warnings qw(redefine once);
local *Mediabot::Quotes::botNotice=sub {push @wire,['notice',$_[1],$_[2]];1};
local *Mediabot::Quotes::botPrivmsg=sub {push @wire,['public',$_[1],$_[2]];1};
local $SIG{__WARN__}=sub {push @warnings,@_};

sub setup_1352 {
    my ($raise,$fault)=@_;
    my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{
        RootClass=>'MB976::DBI',RaiseError=>$raise,PrintError=>0});
    $db->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT)');
    $db->do('CREATE TABLE USER(id_user INTEGER PRIMARY KEY,nickname TEXT)');
    $db->do('CREATE TABLE QUOTES(id_quotes INTEGER PRIMARY KEY,id_channel INTEGER,id_user INTEGER,quotetext TEXT)');
    $db->do(q{INSERT INTO CHANNEL VALUES(1,'#test'),(2,'#other')});
    $db->do(q{INSERT INTO USER VALUES(7,'Author'),(8,'OtherAuthor'),(9,'Bob_'),(10,'BobX')});
    $db->do(q{INSERT INTO QUOTES VALUES
        (1,1,7,'first'),(2,1,7,'second'),(3,1,8,'third'),
        (4,1,NULL,'anonymous'),(5,1,9,'underscore'),(6,1,10,'ordinary'),
        (7,2,7,'other channel')});
    $db->do('PRAGMA query_only=ON');
    $db->{private_ready}=1; $db->{private_fault}=$fault;
    $db->{private_queries}=0; $db->{private_finished}=0;
    my $bot=Mediabot->new({dbh=>$db});
    $bot->{logger}=bless {lines=>[]},'MB976::Log';
    return ($bot,$db);
}
sub invoke_1352 {
    my ($entry,$bot,$target,$channel)=@_;
    @wire=();@warnings=();
    my $result;
    my $ok=eval {
        if ($entry =~ /^registry:(.+)$/) {
            my $name=$1;
            my @args=(($name eq 'quote'?('count'):()),defined($target)?($target):());
            my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Reader',channel=>$channel,
                command=>$name,args=>\@args);
            $result=$bot->command_registry->handler_for($name,'public')->($ctx);
        } else {
            no strict 'refs';
            $result=&{"${entry}::mbQuoteCount_ctx"}($bot,'Reader',$channel,$target);
        }
        1;
    };
    return ($ok?'':$@,$result);
}
my @entries=qw(Mediabot::Quotes Mediabot registry:quotecount registry:quote);
for my $entry (@entries) {
    for my $raise (0,1) {
        for my $target (undef,'Author') {
            for my $fault (qw(prepare execute fetch fetch_die row_error no_row missing_count)) {
                my ($bot,$db)=setup_1352($raise,$fault);
                my $label="$entry RaiseError=$raise ".($target//'total')." $fault";
                my ($error,$result)=invoke_1352($entry,$bot,$target,'#test');
                is($error,'',"$label: database failure remains inside the count handler");
                is_deeply(\@wire,[['notice','Reader','Database error.']],
                    "$label: fixed error notice replaces a fabricated count or silent failure");
                ok(!defined($result),"$label: failed count is not acknowledged as success");
                is($db->{private_queries},1,"$label: one read attempt without implicit retry");
                is($db->{private_finished},$fault eq 'prepare'?0:1,
                    "$label: every allocated cursor gets a cleanup attempt");
                is(scalar @warnings,0,"$label: no uninitialized or driver warning escapes");
                unlike(join(' ',@{$bot->{logger}{lines}}),qr/private count/,
                    "$label: raw database details do not enter runtime logs");
            }
        }
        for my $fault ('','finish') {
            for my $case (
                [undef,'#test',6],['Author','#test',2],['aUtH','#test',2],
                ['Bob_','#test',1],['Absent','#test',0],[undef,'#empty',0],
                [undef,'#other',1],['Author','#other',1],
            ) {
                my ($target,$channel,$count)=@$case;
                my ($bot,$db)=setup_1352($raise,$fault);
                my $label="$entry RaiseError=$raise '$fault' $channel ".($target//'total');
                my ($error,$result)=invoke_1352($entry,$bot,$target,$channel);
                is($error,'',"$label: confirmed count survives cleanup failure");
                my $text=defined($target)?"$target: $count quote(s) on $channel"
                    :"$channel: $count quote(s) total";
                is_deeply(\@wire,[['public',$channel,$text]],
                    "$label: real count keeps the established public rendering");
                is($result,1,"$label: genuine zero or positive count remains successful");
                is($db->{private_queries},1,"$label: one scoped read");
                is($db->{private_finished},1,"$label: completed cursor is finished once");
                is(scalar @warnings,0,"$label: healthy or cleanup-fault path has no warning");
            }
        }
    }
}

for my $raise (0,1) {
    my ($bot,$db)=setup_1352($raise,'fetch');
    invoke_1352('registry:quotecount',$bot,undef,'#test');
    $db->{private_fault}='';
    my ($error)=invoke_1352('registry:quotecount',$bot,undef,'#test');
    is($error,'',"RaiseError=$raise: next explicit command recovers");
    is_deeply(\@wire,[['public','#test','#test: 6 quote(s) total']],
        "RaiseError=$raise: recovery publishes the real count");
    is($db->{private_queries},2,"RaiseError=$raise: one read per explicit command");
}
done_testing;
