# t/cases/163_usercommands_add_del_ctx_args_defensive.t
# =============================================================================
# Regression checks for UserCommands context argument handling.
#
# addUser_ctx() and delUser_ctx() should not assume $ctx->args is always an
# ARRAY reference. The undef-only form @{ $ctx->args // [] } still dies if args
# is a scalar or another non-ARRAY value.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_usercommands_ctx_args {
    my ($path) = @_;

    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_usercommands_ctx_args {
    my ($src, $sub_name) = @_;

    my $start_re = qr/^sub\s+\Q$sub_name\E\s*\{/m;
    return undef unless $src =~ /$start_re/g;

    my $start = pos($src);
    my $depth = 1;
    my $pos   = $start;
    my $len   = length($src);

    while ($pos < $len) {
        my $char = substr($src, $pos, 1);

        if ($char eq '{') {
            $depth++;
        }
        elsif ($char eq '}') {
            $depth--;

            if ($depth == 0) {
                return substr($src, $start, $pos - $start);
            }
        }

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_usercommands_ctx_args(
        File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm')
    );

    my $add_body = _extract_sub_body_usercommands_ctx_args($src, 'addUser_ctx');
    my $del_body = _extract_sub_body_usercommands_ctx_args($src, 'delUser_ctx');

    $assert->ok(
        defined $add_body,
        'addUser_ctx body found'
    );

    $assert->ok(
        defined $del_body,
        'delUser_ctx body found'
    );

    $assert->like(
        $add_body // '',
        qr/my \@args\s+= \(ref\(\$ctx->args\) eq 'ARRAY'\) \? \@\{ \$ctx->args \} : \(\);/,
        'addUser_ctx reads context args defensively'
    );

    $assert->unlike(
        $add_body // '',
        qr/my \@args\s+= \@\{ \$ctx->args \/\/ \[\] \};/,
        'addUser_ctx no longer uses undef-only args fallback'
    );

    $assert->like(
        $add_body // '',
        qr/my \(\$name, \$mask, \$level\) = \@args;/,
        'addUser_ctx still extracts name, mask and level from args'
    );

    $assert->like(
        $del_body // '',
        qr/my \@args\s+= \(ref\(\$ctx->args\) eq 'ARRAY'\) \? \@\{ \$ctx->args \} : \(\);/,
        'delUser_ctx reads context args defensively'
    );

    $assert->unlike(
        $del_body // '',
        qr/my \@args\s+= \@\{ \$ctx->args \/\/ \[\] \};/,
        'delUser_ctx no longer uses undef-only args fallback'
    );

    $assert->like(
        $del_body // '',
        qr/shift \@args if \@args && lc\(\$args\[0\]\) eq lc\(\$nick\);/,
        'delUser_ctx still removes injected caller nick when present'
    );


    # MB928: execute the real destructive handler against isolated DBI/SQLite
    # connections; grouping keeps the historical catalogue and assertion growth small.
    use utf8;
    require File::Temp;
    require JSON::PP;
    my ($child, $child_path) = File::Temp::tempfile(SUFFIX => '.pl', UNLINK => 1);
    binmode($child, ':encoding(UTF-8)');
    print {$child} <<'MB928_NATIVE';
use strict;
use warnings;
use utf8;
BEGIN {$MB928::Clock::now=1000; *CORE::GLOBAL::time=sub () {$MB928::Clock::now}}
use DBI;
use JSON::PP;
use File::Temp qw(tempdir);
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::User;
{
    package MB928::Logger;
    sub log {push @{$_[0]{rows}},[@_[1..$#_]];1}
    package MB928::DBI;
    our @ISA=('DBI');
    package MB928::DBI::db;
    our @ISA=('DBI::db');
    sub begin_work {my $s=shift;push @{$s->{private_mb928_trace}},['begin_work'] if $s->{private_mb928_trace};$s->SUPER::begin_work(@_)}
    sub commit {my $s=shift;push @{$s->{private_mb928_trace}},['commit'] if $s->{private_mb928_trace};$s->SUPER::commit(@_)}
    sub rollback {my $s=shift;push @{$s->{private_mb928_trace}},['rollback'] if $s->{private_mb928_trace};$s->SUPER::rollback(@_)}
    sub do {my ($s,$sql,$attr,@bind)=@_;push @{$s->{private_mb928_trace}},['do',$sql,@bind] if $s->{private_mb928_trace};$s->SUPER::do($sql,$attr,@bind)}
    package MB928::DBI::st;
    our @ISA=('DBI::st');
}
my $json=JSON::PP->new->canonical->utf8;
sub snapshot {
    my ($db)=@_;my %out;
    for my $table (qw(USER USER_CHANNEL USER_HOSTMASK USER_SEEN GUARD OUTER_WORK)) {
        $out{$table}=$db->selectall_arrayref("SELECT * FROM $table ORDER BY 1,2",{Slice=>{}});
    }
    return \%out;
}
sub run {
    my (%a)=@_;$MB928::Clock::now=1000;
    my $dir=tempdir(CLEANUP=>1);
    my $dsn="dbi:SQLite:dbname=$dir/users.sqlite";
    my $db=DBI->connect($dsn,'','',{RaiseError=>$a{raise}//0,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1,RootClass=>'MB928::DBI'});
    $db->do('PRAGMA foreign_keys=ON');
    $db->do('CREATE TABLE USER (id_user INTEGER PRIMARY KEY, nickname TEXT UNIQUE)');
    $db->do('CREATE TABLE USER_CHANNEL (id_user INTEGER, id_channel INTEGER, level INTEGER)');
    $db->do('CREATE TABLE USER_HOSTMASK (id_user INTEGER, hostmask TEXT)');
    $db->do('CREATE TABLE USER_SEEN (nick TEXT PRIMARY KEY, event_type TEXT)');
    $db->do('CREATE TABLE GUARD (id_user INTEGER REFERENCES USER(id_user) DEFERRABLE INITIALLY DEFERRED, label TEXT)');
    $db->do('CREATE TABLE OUTER_WORK (id INTEGER, label TEXT)');
    my $target=$a{target}//'Étoile';
    for my $row ([7,$target],[9,'Bob']) {$db->do('INSERT INTO USER VALUES (?,?)',undef,@$row)}
    for my $row ([7,4,100],[7,8,200],[9,4,500]) {$db->do('INSERT INTO USER_CHANNEL VALUES (?,?,?)',undef,@$row)}
    for my $row ([7,'*!a@one'],[7,'*!b@two'],[9,'*!c@three']) {$db->do('INSERT INTO USER_HOSTMASK VALUES (?,?)',undef,@$row)}
    for my $row ([lc($target),'PRIVMSG'],['bob','JOIN']) {$db->do('INSERT INTO USER_SEEN VALUES (?,?)',undef,@$row)}
    if ($a{empty_links}) {for my $table (qw(USER_CHANNEL USER_HOSTMASK)) {$db->do("DELETE FROM $table WHERE id_user=7")};$db->do('DELETE FROM USER_SEEN WHERE nick=?',undef,lc($target))}
    my $fault=$a{fault}//'';
    if ($fault =~ /\Adelete:(USER_CHANNEL|USER_HOSTMASK|USER_SEEN|USER)\z/) {
        my $table=$1;my $when=$table eq 'USER_SEEN' ? "OLD.nick='".lc($target)."'" : 'OLD.id_user=7';
        $db->do("CREATE TRIGGER refuse_delete BEFORE DELETE ON $table WHEN $when BEGIN SELECT RAISE(ABORT, 'fixture refusal $table'); END");
    }
    if ($fault eq 'commit') {$db->do("INSERT INTO GUARD VALUES (7,'retain target')")}
    my $peer=DBI->connect($dsn,'','',{RaiseError=>1,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
    my $before=snapshot($db);my @trace;$db->{private_mb928_trace}=\@trace;
    my $logger=bless({rows=>[]},'MB928::Logger');
    my $bot=bless({dbh=>$db,logger=>$logger},'Mediabot');
    my $principal=Mediabot::User->new({id_user=>1,nickname=>'Operator',auth=>1});
    $principal->{level_desc}=$a{low_level} ? 'User' : 'Master';
    $principal->{auth}=0 if $a{unauthenticated};
    my (@wire,@audit,@warnings,@returns,@errors,@states);
    no warnings qw(redefine once);
    my $notice=sub {push @wire,[@_[1..$#_]];1};
    local *Mediabot::UserCommands::botNotice=$notice;
    local *Mediabot::botNotice=$notice;
    local *Mediabot::UserCommands::logBot=sub {push @audit,[@_[2..$#_]];1};
    local $SIG{__WARN__}=sub {push @warnings,@_};
    my $handler=sub {
        my ($args,$nick)=@_;$nick//='Operator';
        my $ctx=Mediabot::Context->new(bot=>$bot,nick=>$nick,channel=>'#test',command=>'deluser',args=>$args);
        $ctx->{user}=$principal;$ctx->{_user_fetched}=1;
        my $value;my $ok=eval {
            $value=$a{entry} eq 'imported' ? Mediabot::delUser_ctx($ctx) : Mediabot::UserCommands::delUser_ctx($ctx);
            1;
        };
        push @returns,$value;push @errors,$ok ? '' : "$@";
        push @states,snapshot($db);
    };
    my $args=$a{missing} ? [] : $a{unknown} ? ['Nobody'] : $a{injected} ? ['Operator',$target] : [$target];
    $handler->($args);
    if (!$a{single}) {
        $MB928::Clock::now=1000+($a{delay}//1);
        if ($fault eq 'begin') {
            $db->begin_work;
            $db->do("INSERT INTO OUTER_WORK VALUES (1,'caller pending')");
            @trace=();
        }
        $handler->($args,$a{other_actor} ? 'OtherOperator' : undef);
    }
    my $after=snapshot($db);my $peer_after=snapshot($peer);
    my $result={args=>\%a,before=>$before,after=>$after,peer_after=>$peer_after,states=>\@states,
        wire=>\@wire,audit=>\@audit,logs=>$logger->{rows},trace=>\@trace,
        returns=>\@returns,errors=>\@errors,warnings=>\@warnings,autocommit=>$db->{AutoCommit}?1:0,
        pending=>[sort grep {/^_deluser_pending_/} keys %$bot]};
    $db->{private_mb928_trace}=undef;
    $db->rollback unless $db->{AutoCommit};
    $db->disconnect;$peer->disconnect;
    return $result;
}
my @records;
for my $entry (qw(module imported)) {
    for my $raise (0,1) {
        for my $fault (qw(delete:USER_CHANNEL delete:USER_HOSTMASK delete:USER_SEEN delete:USER commit begin)) {
            push @records,run(entry=>$entry,raise=>$raise,fault=>$fault);
        }
        for my $a ({},{empty_links=>1},{injected=>1},{single=>1},{delay=>30},{delay=>31},
            {other_actor=>1},{missing=>1},{unknown=>1},{low_level=>1},{unauthenticated=>1},
            {target=>'Alice'}) {
            push @records,run(entry=>$entry,raise=>$raise,nominal=>1,%$a);
        }
    }
}
print $json->encode(\@records);
MB928_NATIVE
    close $child or die "cannot write native deluser probe: $!";
    open my $reader, '-|', $^X, '-I.', '-It/lib', $child_path
        or die "cannot start native deluser probe: $!";
    my $raw = do { local $/; <$reader> };
    close $reader;
    my $status = $?;
    my $records = eval { JSON::PP::decode_json($raw) };
    $assert->ok($status == 0 && ref($records) eq 'ARRAY' && @$records == 72,
        'MB928: 72 native deluser scenarios completed through module and imported entry');
    $records = [] unless ref($records) eq 'ARRAY';
    my $json = JSON::PP->new->canonical->utf8;
    my $same = sub { $json->encode($_[0]) eq $json->encode($_[1]) };
    my (@sql_errors, @ownership_errors, @nominal_errors);
    my ($sql_count, $ownership_count, $nominal_count) = (0, 0, 0);
    for my $r (@$records) {
        my $a = $r->{args};
        my $label = join('/', $a->{entry}, $a->{raise}, $a->{fault} // 'nominal',
            sort grep { $_ ne 'entry' && $_ ne 'raise' && $_ ne 'nominal' } keys %$a);
        my $target = $a->{target} // 'Étoile';
        my $warning = "WARNING: This will permanently delete user '$target' (id=7). Repeat the command within 30s to confirm.";
        my @deletes = (
            ['do', 'DELETE FROM USER_CHANNEL  WHERE id_user=?', 7],
            ['do', 'DELETE FROM USER_HOSTMASK WHERE id_user=?', 7],
            ['do', 'DELETE FROM USER_SEEN     WHERE nick = ?', lc($target)],
            ['do', 'DELETE FROM USER          WHERE id_user=?', 7],
        );
        if (!$a->{nominal}) {
            my $outer = $a->{fault} eq 'begin';
            $outer ? $ownership_count++ : $sql_count++;
            my $expected = JSON::PP::decode_json($json->encode($r->{before}));
            $expected->{OUTER_WORK} = [{id => 1, label => 'caller pending'}] if $outer;
            my @trace = (['begin_work']);
            if (!$outer) {
                if ($a->{fault} eq 'commit') {push @trace, @deletes, ['commit']}
                else {
                    my %index = (USER_CHANNEL => 0, USER_HOSTMASK => 1, USER_SEEN => 2, USER => 3);
                    (my $table = $a->{fault}) =~ s/^delete://;
                    push @trace, @deletes[0 .. $index{$table}];
                }
                push @trace, ['rollback'];
            }
            # SQLite/DBI can warn after a deferred-constraint commit refusal;
            # verify actual restoration on both connections, not that warning's wording.
            my $warnings_ok = !@{$r->{warnings}} || ($a->{fault} eq 'commit'
                && @{$r->{warnings}} == 1 && $r->{warnings}[0] =~ /^rollback ineffective with AutoCommit enabled/);
            my $diagnostic = @{$r->{logs}} == 1 && $r->{logs}[0][0] == 0
                && $r->{logs}[0][1] =~ /^delUser_ctx: transaction failed for \Q$target\E: \S/;
            my $ok = $same->($r->{after}, $expected)
                && $same->($r->{peer_after}, $r->{before})
                && $same->($r->{states}[0], $r->{before})
                && $same->($r->{states}[1], $expected)
                && $same->($r->{wire}, [['Operator',$warning], ['Operator','Database error -- user not deleted.']])
                && $same->($r->{returns}, [undef,undef])
                && $same->($r->{errors}, ['', '']) && $warnings_ok && $diagnostic
                && !@{$r->{audit}} && !@{$r->{pending}}
                && $same->($r->{trace}, \@trace) && $r->{autocommit} == ($outer ? 0 : 1);
            push @{ $outer ? \@ownership_errors : \@sql_errors }, $label unless $ok;
            next;
        }
        $nominal_count++;
        my $blocked = $a->{missing} || $a->{unknown} || $a->{low_level} || $a->{unauthenticated};
        my $success = !$blocked && !$a->{single} && !$a->{other_actor} && ($a->{delay} // 1) <= 30;
        my $expected = JSON::PP::decode_json($json->encode($r->{before}));
        if ($success) {
            for my $table (qw(USER USER_CHANNEL USER_HOSTMASK)) {
                $expected->{$table} = [grep { $_->{id_user} != 7 } @{$expected->{$table}}];
            }
            $expected->{USER_SEEN} = [grep { $_->{nick} ne lc($target) } @{$expected->{USER_SEEN}}];
        }
        my $count = $a->{single} ? 1 : 2;
        my (@wire, @pending, @trace, @audit, @logs);
        my $message = "User $target (id_user: 7) has been deleted";
        if ($blocked) {
            my $text = $a->{missing} ? 'Syntax: deluser <username>'
                : $a->{unknown} ? 'Undefined user Nobody'
                : $a->{unauthenticated} ? 'You must be logged in to use this command.'
                : 'Your level does not allow you to use this command.';
            @wire = map { ['Operator',$text] } 1..$count;
        }
        else {
            @wire = (['Operator',$warning]);
            if ($success) {
                push @wire, ['Operator',$message];
                @trace = (['begin_work'], @deletes, ['commit']);
                @audit = ([undef,'deluser',$message]);
                @logs = ([0,"delUser_ctx: $message (by Operator)"]);
            }
            else {
                @pending = ("_deluser_pending_Operator_$target");
                if (!$a->{single}) {
                    push @wire, [$a->{other_actor} ? 'OtherOperator' : 'Operator',$warning];
                    push @pending, "_deluser_pending_OtherOperator_$target" if $a->{other_actor};
                }
            }
        }
        my @returns = map {undef} 1..$count;
        $returns[-1] = 1 if $success;
        my @errors = map {''} 1..$count;
        my $ok = $same->($r->{after},$expected) && $same->($r->{peer_after},$expected)
            && $same->($r->{states}[0],$r->{before})
            && $same->($r->{states}[-1],$expected)
            && $same->($r->{wire},\@wire) && $same->($r->{audit},\@audit)
            && $same->($r->{logs},\@logs) && $same->($r->{trace},\@trace)
            && $same->($r->{returns},\@returns) && $same->($r->{errors},\@errors)
            && $same->($r->{pending},[sort @pending]) && !@{$r->{warnings}} && $r->{autocommit} == 1;
        push @nominal_errors, $label unless $ok;
    }
    $assert->is($json->encode([$sql_count,\@sql_errors]), '[20,[]]',
        'MB928: four SQL deletions and commit refuse atomically, stop immediately and retain diagnostics');
    $assert->is($json->encode([$ownership_count,\@ownership_errors]), '[4,[]]',
        'MB928: failed begin neither commits nor rolls back another caller transaction');
    $assert->is($json->encode([$nominal_count,\@nominal_errors]), '[48,[]]',
        'MB928: confirmation, exact 30s boundary, permissions, empty links and Unicode retain native contracts');
};
