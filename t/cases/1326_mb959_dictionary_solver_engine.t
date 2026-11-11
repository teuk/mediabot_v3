use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::Plugin::WordSolverV3;
require './plugins/longest-word-v3/lib/Engine.pm';

my $solver = 'Mediabot::Plugin::WordSolverV3';
is($solver->letters('teaTE'), 'AEETT', 'rack canonicalization keeps repetitions');
my $signatures = $solver->signatures('AAB');
is_deeply($signatures, [qw(AAB AA AB)], 'submultisets are unique and preserve counts');
is(scalar @{ $solver->signatures('ABCDEFGHIJKL') }, 4083, 'twelve distinct letters remain bounded');
is_deeply($solver->signatures('AAAAAAAAAA'), [map { 'A' x $_ } reverse 2..10], 'repeated letters do not cause duplicate queries');
for my $invalid ('', 'A', 'ABCDEFGHIJKLM', "AA\n", "AA' OR 1=1", [], undef) {
    ok(!eval { $solver->letters($invalid); 1 }, 'invalid rack rejected before SQL');
}
my $r = $solver->result('AEEINORSTT', [qw(SERA ETE NOTAIRES ORIENTATES ORIENTATES)]);
is($r->{longest}, 10, 'maximum is computed from validated complete words');
is(scalar @{ $r->{words} }, 4, 'dictionary duplicates are harmless');
ok(!eval { $solver->result('AEEINORSTT', ['TTTT']); 1 }, 'excess letter multiplicity rejected');
ok(!eval { $solver->result('AEEINORSTT', ['été']); 1 }, 'dictionary rows use the actual ASCII contract');
ok(!eval { $solver->result('AA', [('AA') x 4097]); 1 }, 'oversized worker payload rejected');

{
    package MB959::Statement;
    sub execute { my ($s,@bind)=@_; $s->{rows}=[map { [$_,join('',sort split //,$_)] } grep { my $w=$_;grep {$_ eq join('',sort split //,$w)} @bind } @{$s->{db}{words}}];1 }
    sub fetchrow_arrayref { shift @{$_[0]{rows}} }
    sub finish {1}
    sub err {0}
    package MB959::DB;
    sub begin_work {$_[0]{begun}++;1}
    sub rollback {$_[0]{rolled}++;1}
    sub prepare {my ($s,$sql)=@_;push @{$s->{sql}},$sql;bless {db=>$s},'MB959::Statement'}
}
my $db = bless {words=>[qw(SERA ETE NOTAIRES ORIENTATES)]}, 'MB959::DB';
my $read = $solver->solve($db, 'AEEINORSTT');
is_deeply($read->{words}, $r->{words}, 'batched indexed lookups recover all fixture words');
is($db->{rolled}, 1, 'read snapshot always closed without committing');
ok(!grep(!/SELECT `word`,`sorted`.*FORCE INDEX.* IN \((?:\?,?)+\) LIMIT [0-9]+\z/, @{$db->{sql}}), 'only fixed, parameterized indexed SELECTs are prepared');
ok(@{$db->{sql}} > 1 && @{$db->{sql}} < 9, 'one query per signature is replaced by bounded batches');

is(Mediabot::Plugin::LongestWord::Engine::normalize('été'), 'ETE', 'French accents normalize to dictionary spelling');
is(Mediabot::Plugin::LongestWord::Engine::normalize('cœur'), 'COEUR', 'French ligatures normalize explicitly');
ok(!defined Mediabot::Plugin::LongestWord::Engine::normalize('deux mots'), 'phrases are not guesses');
ok(!defined Mediabot::Plugin::LongestWord::Engine::normalize("ETE\0"), 'controls are rejected');
is(Mediabot::Plugin::LongestWord::Engine::fold('#Te[st]'), '#te{st}', 'RFC1459 channel identity');
my $e = Mediabot::Plugin::LongestWord::Engine->new(rounds=>2,duration=>50,bonus=>3);
$e->begin_round(words=>$read->{words},letters=>'AEEINORSTT',now=>100);
ok($e->submit(id=>'u.2',nick=>'Bob',word=>'NOTAIRES',now=>101)->{ok}, 'first player establishes the round record');
is($e->{phase}, 'playing', 'a non-optimal word keeps the round open');
ok(!defined $e->close_round(101.5), 'non-optimal record cannot close before deadline');
ok($e->submit(id=>'u.1',nick=>'Alice',word=>'ORIENTATES',now=>102)->{ok}, 'a later player can improve the common record');
is($e->submit(id=>'u.3',nick=>'Max',word=>'ORIENTATES',now=>103)->{error}, 'not_longer', 'equal optimal answer cannot match an already accepted record');
is($e->submit(id=>'u.1',nick=>'Alice',word=>'SERA',now=>104)->{error}, 'not_longer', 'shorter guess cannot overwrite the best');
my $closed = $e->close_round(104.5);
ok($closed && $closed->{top_found}, 'an accepted dictionary maximum permits immediate closure');
is($e->submit(id=>'u.4',nick=>'Late',word=>'ORIENTATES',now=>150)->{error}, 'closed', 'exact deadline rejects guesses');
is_deeply([map {$_->{score}} @{$e->ranking}], [13,8], 'only accepted words receive points, including earlier record holders');
is_deeply($closed->{solutions}, ['ORIENTATES'], 'optimal solutions revealed after closure');
ok(!defined $e->close_round(151), 'duplicate tick cannot award points twice');
$e->{phase}='preparing';
$e->begin_round(words=>$read->{words},letters=>'AEEINORSTT',now=>160);
is($e->submit(id=>'u.2',nick=>'NewBob',word=>'été',now=>161)->{word}, 'ETE', 'authenticated player may change nick');
$e->close_round(210);
is($e->{players}{'u.2'}{score}, 11, 'round scores accumulate within the match');
is($e->{players}{'u.2'}{nick}, 'NewBob', 'display nick follows a stable authenticated identity');
is($e->{phase}, 'done', 'finite match stops automatically');
my $many = Mediabot::Plugin::LongestWord::Engine->new(rounds=>3,duration=>50,bonus=>3);
my @ascending = map { substr('ABCDEFGHIJKL',0,$_) } 2..12;
my $players = 0;
for my $round (1..3) {
    $many->{phase}='preparing' if $round>1;
    $many->begin_round(words=>\@ascending,letters=>'ABCDEFGHIJKL',now=>$round*100);
    for my $word (@ascending) {
        last if $players==32;
        my $id=++$players;
        $many->submit(id=>"u.$id",nick=>"P$id",word=>$word,now=>$round*100+1);
    }
    $many->close_round($round*100+50) if $round<3;
}
is($many->submit(id=>'u.33',nick=>'Extra',word=>'ABCDEFGHIJKL',now=>302)->{error}, 'full', 'match participants remain bounded across rounds');

# MB1186: a failed DB operation must not publish an incomplete dictionary.
{
    package MB1186::DB;
    sub begin_work {
        my ($s)=@_; $s->{begun}++;
        die "private SQL diagnostic\n" if $s->{fault} eq 'begin_die';
        return $s->{fault} eq 'begin_false' ? undef : 1;
    }
    sub prepare {
        my ($s)=@_; $s->{prepared}++;
        return undef if $s->{fault} eq 'prepare';
        return bless {db=>$s,rows=>[['TEA','AET']]}, 'MB1186::Statement';
    }
    sub rollback {
        my ($s)=@_; $s->{rolled}++;
        die "private rollback diagnostic\n" if $s->{fault} eq 'rollback_die';
        return $s->{fault} eq 'rollback_false' ? undef : 1;
    }
    package MB1186::Statement;
    sub execute {$_[0]{db}{fault} eq 'execute' ? undef : '0E0'}
    sub fetchrow_arrayref {shift @{$_[0]{rows}}}
    sub err {$_[0]{db}{fault} eq 'fetch' ? 1 : 0}
    sub finish {$_[0]{db}{finished}++; $_[0]{db}{fault} eq 'finish' ? undef : 1}
}
for my $fault (qw(begin_false begin_die prepare execute fetch finish rollback_false rollback_die)) {
    my $db=bless {fault=>$fault}, 'MB1186::DB';
    my $result; my $ok=eval {$result=$solver->solve($db,'TEA');1};
    ok(!$ok && !defined($result), "$fault does not publish partial or empty success");
    is($@, "dictionary_query\n", "$fault returns only the bounded public error");
    is($db->{rolled}//0, $fault =~ /^begin/ ? 0 : 1,
        "$fault rolls back only a successfully started transaction");
}
my $zero_db=bless {fault=>''}, 'MB1186::DB';
is_deeply($solver->solve($zero_db,'TEA')->{words}, ['TEA'],
    'DBI true-zero execute return remains successful');
is($zero_db->{rolled}, 1, 'successful read snapshot is rolled back once');
# MB1207: release a prepared statement before closing its read transaction.
{
    package MB1207::DB;
    sub begin_work { push @{$_[0]{events}}, 'begin'; 1 }
    sub prepare {
        my ($s)=@_; push @{$s->{events}}, 'prepare';
        die "private prepare failure\n" if $s->{fault} eq 'prepare';
        return bless {db=>$s,rows=>[['TEA','AET']]}, 'MB1207::Statement';
    }
    sub rollback { push @{$_[0]{events}}, 'rollback'; 1 }
    package MB1207::Statement;
    sub execute {
        my ($s)=@_; push @{$s->{db}{events}}, 'execute';
        die "private execute failure\n" if $s->{db}{fault} eq 'execute_die';
        return $s->{db}{fault} eq 'execute_false' ? undef : '0E0';
    }
    sub fetchrow_arrayref {
        my ($s)=@_;
        die "private fetch failure\n" if $s->{db}{fault} eq 'fetch_die';
        my $row=shift @{$s->{rows}};
        $row->[1]='BAD' if $row && $s->{db}{fault} eq 'corrupt';
        return $row;
    }
    sub err { $_[0]{db}{fault} eq 'fetch_error' ? 1 : 0 }
    sub finish {
        my ($s)=@_; push @{$s->{db}{events}}, 'finish';
        die "private finish failure\n" if $s->{db}{cleanup} eq 'die';
        return $s->{db}{cleanup} eq 'false' ? undef : 1;
    }
}
for my $fault (qw(prepare execute_false execute_die fetch_die fetch_error corrupt success)) {
    for my $cleanup (qw(ok false die)) {
        my $db=bless {fault=>$fault,cleanup=>$cleanup,events=>[]}, 'MB1207::DB';
        my $result; my $ok=eval {$result=$solver->solve($db,'TEA');1};
        my $error=$@;
        my $success=$fault eq 'success' && $cleanup eq 'ok';
        is_deeply([$ok ? 1 : 0,$error,$result],
            $success ? [1,'',$solver->result('TEA',['TEA'])] : [0,"dictionary_query\n",undef],
            "mb1207: $fault / $cleanup retains result and public error policy");
        is_deeply($db->{events},$fault eq 'prepare' ? [qw(begin prepare rollback)]
            : [qw(begin prepare execute finish rollback)],
            "mb1207: $fault / $cleanup finishes once before rollback");
    }
}
done_testing;
