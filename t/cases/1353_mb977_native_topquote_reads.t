use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use Mediabot::Mediabot;
use Mediabot::Context;

{
    package MB977::DBI; our @ISA=('DBI');
    package MB977::DBI::db; our @ISA=('DBI::db');
    sub prepare {
        my ($db,$sql,@rest)=@_;
        my $index=0;
        if ($db->{private_ready}) {
            die 'topquote must remain read-only' unless $sql =~ /^\s*SELECT\b/i;
            $index=++$db->{private_queries};
            return $db->set_err(1,'private ranking prepare detail')
                if ($db->{private_faults}{$index}//'') eq 'prepare';
        }
        my $sth=$db->SUPER::prepare($sql,@rest);
        if ($sth && $index) {
            $sth->{private_index}=$index;
            push @{$db->{private_prepared}},$index;
        }
        return $sth;
    }
    package MB977::DBI::st; our @ISA=('DBI::st');
    sub execute {
        my ($sth,@bind)=@_;
        my $index=$sth->{private_index};
        push @{$sth->{Database}{private_binds}},[$index,@bind];
        return $sth->set_err(1,'private ranking execute detail')
            if ($sth->{Database}{private_faults}{$index}//'') eq 'execute';
        return $sth->SUPER::execute(@bind);
    }
    sub fetchall_arrayref {
        my ($sth,@args)=@_;
        my $fault=$sth->{Database}{private_faults}{$sth->{private_index}}//'';
        die "private ranking fetch exception\n" if $fault eq 'fetch_die';
        if ($fault eq 'fetch_empty') {
            $sth->set_err(1,'private ranking empty fetch detail');
            return [];
        }
        my $rows=$sth->SUPER::fetchall_arrayref(@args);
        if ($fault eq 'fetch_partial') {
            $rows=[@$rows[0..0]] if $rows && @$rows;
            $sth->set_err(1,'private ranking partial fetch detail');
        }
        return $rows;
    }
    sub finish {
        my ($sth)=@_;
        my $index=$sth->{private_index};
        push @{$sth->{Database}{private_finished}},$index;
        my $ok=$sth->SUPER::finish;
        $sth->set_err(undef,undef);
        die "private ranking cleanup detail\n"
            if ($sth->{Database}{private_faults}{$index}//'') eq 'finish';
        return $ok;
    }
    package MB977::Log; sub log {push @{$_[0]{lines}},$_[2];1}
}
$INC{'MB977/DBI.pm'}=__FILE__;
my (@wire,@warnings);
no warnings qw(redefine once);
local *Mediabot::Quotes::botNotice=sub {push @wire,['notice',$_[1],$_[2]];1};
local *Mediabot::Quotes::botPrivmsg=sub {push @wire,['public',$_[1],$_[2]];1};
local $SIG{__WARN__}=sub {push @warnings,@_};

sub setup_1353 {
    my ($raise,$legacy,$faults)=@_;
    my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{
        RootClass=>'MB977::DBI',RaiseError=>$raise,PrintError=>0});
    $db->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT)');
    $db->do('CREATE TABLE USER(id_user INTEGER PRIMARY KEY,nickname TEXT)');
    $db->do('CREATE TABLE QUOTES(id_quotes INTEGER PRIMARY KEY,id_channel INTEGER,id_user INTEGER,quotetext TEXT'
        .($legacy?'':',hits INTEGER').')');
    $db->do(q{INSERT INTO CHANNEL VALUES(1,'#test'),(2,'#other')});
    $db->do(q{INSERT INTO USER VALUES(7,'Alice'),(8,'Bob')});
    my @rows=([1,1,7,'first',1],[2,1,8,'second',9],[3,1,undef,'anonymous',0],[50,2,7,'foreign',100]);
    for my $row (@rows) {
        my @data=@$row;pop @data if $legacy;
        $db->do('INSERT INTO QUOTES VALUES('.join(',',('?')x@data).')',undef,@data);
    }
    $db->do('PRAGMA query_only=ON');
    $db->{private_ready}=1;$db->{private_faults}=$faults//{};
    $db->{private_queries}=0;$db->{private_prepared}=[];
    $db->{private_finished}=[];$db->{private_binds}=[];
    my $bot=Mediabot->new({dbh=>$db});
    $bot->{logger}=bless {lines=>[]},'MB977::Log';
    return ($bot,$db);
}
sub invoke_1353 {
    my ($entry,$bot,$channel,$limit)=@_;
    @wire=();@warnings=();
    my $result;
    my $ok=eval {
        if ($entry =~ /^registry:(.+)$/) {
            my $name=$1;
            my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Reader',channel=>$channel,
                command=>$name,args=>defined($limit)?[$limit]:[]);
            $result=$bot->command_registry->handler_for($name,'public')->($ctx);
        } else {
            no strict 'refs';
            $result=&{"${entry}::mbTopQuote_ctx"}($bot,'Reader',$channel,$limit);
        }
        1;
    };
    return ($ok?'':$@,$result);
}
sub expected_1353 {
    my ($ranked,$limit)=@_;$limit//=5;
    my @rows=$ranked
        ? ([2,'Bob','second',9],[1,'Alice','first',1],[3,'?','anonymous',0])
        : ([3,'?','anonymous',0],[2,'Bob','second',9],[1,'Alice','first',1]);
    splice @rows,$limit if @rows>$limit;
    my @out=(['public','#test',$ranked
        ? "\x02Hall of fame\x02 #test — most recalled quotes:"
        : "\x02Quotes\x02 #test — latest:"]);
    my $rank=0;
    for my $r (@rows) {
        my ($id,$author,$text,$hits)=@$r;
        my $suffix=$ranked?' ('.$hits.' recall'.($hits==1?'':'s').')':'';
        push @out,['public','#test',sprintf('  %d. [id:%d] <%s> %s%s',++$rank,$id,$author,$text,$suffix)];
    }
    return \@out;
}
my @entries=qw(Mediabot::Quotes Mediabot registry:topquote registry:halloffame);
for my $entry (@entries) {
    for my $raise (0,1) {
        # Both normal ranking and an actual schema without hits remain usable.
        for my $legacy (0,1) {
            for my $cleanup (0,1) {
                my ($bot,$db)=setup_1353($raise,$legacy,$cleanup?{($legacy?2:1)=>'finish'}:{});
                my $label="$entry RaiseError=$raise legacy=$legacy cleanup=$cleanup";
                my ($error,$result)=invoke_1353($entry,$bot,'#test',undef);
                is($error,'',"$label: healthy or legacy-schema read completes");
                is_deeply(\@wire,expected_1353(!$legacy),"$label: exact complete result, author, order and recall grammar");
                is($result,1,"$label: completed listing stays successful");
                is($db->{private_queries},$legacy?2:1,"$label: legacy query runs only when necessary");
                is_deeply($db->{private_finished},$db->{private_prepared},"$label: all allocated cursors get cleanup");
                is(scalar @warnings,0,"$label: no warning escapes");
            }
        }
        for my $fault (qw(prepare execute fetch_die fetch_empty fetch_partial)) {
            my ($bot,$db)=setup_1353($raise,0,{1=>$fault});
            my $label="$entry RaiseError=$raise primary $fault";
            my ($error)=invoke_1353($entry,$bot,'#test',undef);
            is($error,'',"$label: primary read failure is contained");
            is_deeply(\@wire,expected_1353(0),"$label: failed/partial ranking is replaced only by a confirmed latest listing");
            is($db->{private_queries},2,"$label: one legacy fallback, no repeated primary query");
            is_deeply($db->{private_finished},$db->{private_prepared},"$label: failed and successful cursors get cleanup");
            is(scalar @warnings,0,"$label: no driver warning escapes");
        }
        for my $fault (qw(prepare execute fetch_die fetch_empty fetch_partial)) {
            for my $legacy (0,1) {
                my $faults=$legacy?{2=>$fault}:{1=>'fetch_partial',2=>$fault};
                my ($bot,$db)=setup_1353($raise,$legacy,$faults);
                my $label="$entry RaiseError=$raise legacy=$legacy fallback $fault";
                my ($error,$result)=invoke_1353($entry,$bot,'#test',undef);
                is($error,'',"$label: fallback error is contained");
                is_deeply(\@wire,[['notice','Reader','topquote: database unavailable.']],
                    "$label: failed reads never become an empty or partial public listing");
                ok(!defined($result),"$label: failed listing is not acknowledged as success");
                is($db->{private_queries},2,"$label: no extra retries");
                is_deeply($db->{private_finished},$db->{private_prepared},"$label: every allocated cursor gets cleanup");
                is(scalar @warnings,0,"$label: no raw driver warning escapes");
                unlike(join(' ',@{$bot->{logger}{lines}}),qr/private ranking/,
                    "$label: driver details do not enter runtime logs");
            }
        }
        for my $legacy (0,1) {
            my ($bot,$db)=setup_1353($raise,$legacy,{});
            my ($error)=invoke_1353($entry,$bot,'#empty',undef);
            is($error,'',"$entry legacy=$legacy: real empty channel completes");
            is_deeply(\@wire,[['public','#empty',
                'No quotes yet on #empty — add some with !q add <text>.']],
                "$entry legacy=$legacy: only confirmed absence produces the empty message");
        }
        for my $spec ([0,1],[99,10]) {
            my ($bot,$db)=setup_1353($raise,0,{});
            invoke_1353($entry,$bot,'#test',$spec->[0]);
            is_deeply(\@wire,expected_1353(1,$spec->[1]),"$entry: requested limit is bounded");
            is_deeply($db->{private_binds},[[1,'#test',$spec->[1]]],
                "$entry: actual query binds the channel and bounded limit");
        }
    }
}
done_testing;
