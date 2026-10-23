# t/cases/165_logincommands_userlogin_ctx_args_defensive.t
# =============================================================================
# Regression checks for LoginCommands::userLogin_ctx().
#
# userLogin_ctx() should not assume $ctx->args is always an ARRAY reference.
# The undef-only form @{ $ctx->args // [] } still dies if args is a scalar or
# another non-ARRAY value.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_login_userlogin_ctx_args {
    my ($path) = @_;

    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_login_userlogin_ctx_args {
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

    my $src = _slurp_login_userlogin_ctx_args(
        File::Spec->catfile('.', 'Mediabot', 'LoginCommands.pm')
    );

    my $body = _extract_sub_body_login_userlogin_ctx_args($src, 'userLogin_ctx');

    $assert->ok(
        defined $body,
        'userLogin_ctx body found'
    );

    $assert->like(
        $body // '',
        qr/my \@tArgs\s+= \(ref\(\$ctx->args\) eq 'ARRAY'\) \? \@\{ \$ctx->args \} : \(\);/,
        'userLogin_ctx reads context args defensively'
    );

    $assert->unlike(
        $body // '',
        qr/my \@tArgs\s+= \@\{ \$ctx->args \/\/ \[\] \};/,
        'userLogin_ctx no longer uses undef-only args fallback'
    );

    $assert->like(
        $body // '',
        qr/shift \@tArgs;/,
        'userLogin_ctx still removes injected caller nick when present'
    );

    $assert->like(
        $body // '',
        qr/login <username> <password>/,
        'userLogin_ctx still keeps its login syntax message'
    );

    $assert->like(
        $body // '',
        qr/my \$max_fail = 5;/,
        'userLogin_ctx still keeps brute-force throttle logic'
    );

    # MB923: real command, credential verifier and SQLite statements. A shared
    # normalized actor/account key counts one failure, while both scopes remain.
    require JSON::PP;
    my $probe = <<'MB923_NATIVE';
use strict;
use warnings;
use utf8;
BEGIN {
    $MB923::Clock::now = 2_000_000_000;
    *CORE::GLOBAL::time = sub { $MB923::Clock::now };
}
use DBI;
use Digest::SHA qw(sha1);
use JSON::PP;
use Mediabot::LoginCommands;
use Mediabot::Auth;
{
    package MB923::DBI; our @ISA = ('DBI');
    package MB923::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($s, $sql, @rest) = @_;
        my $trace = $s->{private_mb923};
        push @{$trace->{sql}}, $sql if $trace;
        my $sth = $s->SUPER::prepare($sql, @rest);
        $sth->{private_mb923} = {trace => $trace, sql => $sql} if $sth && $trace;
        return $sth;
    }
    package MB923::DBI::st; our @ISA = ('DBI::st');
    sub execute {
        my ($s, @bind) = @_;
        my $p = $s->{private_mb923};
        # Bcrypt lazy upgrades have random salts; validate rather than compare it.
        if ($p && $p->{sql} eq 'UPDATE USER SET password = ? WHERE id_user = ?') {
            $bind[0] = Mediabot::Auth::password_matches('fixture-right', $bind[0])
                ? '<valid fixture hash>' : '<invalid fixture hash>';
        }
        push @{$p->{trace}{binds}}, [$p->{sql}, @bind] if $p;
        return $s->SUPER::execute(@_[1..$#_]);
    }
    package MB923::Log; sub log {1}
    package MB923::IRC; sub nick_folded {'mediabot'}
    package MB923::Metrics;
    sub inc {$_[0]{values}{$_[1]}++; 1}
    sub set {$_[0]{values}{$_[1]} = $_[2]; 1}
    package MB923::Bot;
    sub noticeConsoleChan {push @{$_[0]{console}}, $_[1]; 1}
    package MB923::Message; sub prefix {$_[0]{nick}.'!ident@fixture.example'}
    package MB923::Ctx;
    sub bot {$_[0]{bot}} sub nick {$_[0]{nick}} sub args {$_[0]{args}}
    sub message {bless {nick => $_[0]{nick}}, 'MB923::Message'}
}
$INC{'MB923/DBI.pm'} = __FILE__;
sub fixture {
    $MB923::Clock::now = 2_000_000_000;
    my $h = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {
        RootClass => 'MB923::DBI', RaiseError => 1, PrintError => 0,
        AutoCommit => 1, sqlite_unicode => 1});
    $h->sqlite_create_function('NOW', 0, sub {'2033-05-18 03:33:20'});
    $h->do(q{CREATE TABLE USER(id_user INTEGER PRIMARY KEY,nickname TEXT COLLATE NOCASE,
        password TEXT,id_user_level INTEGER,auth INTEGER,last_login TEXT)});
    $h->do(q{CREATE TABLE USER_LEVEL(id_user_level INTEGER,description TEXT)});
    $h->do(q{CREATE TABLE USER_HOSTMASK(id_user_hostmask INTEGER PRIMARY KEY,id_user INTEGER,hostmask TEXT)});
    $h->do(q{INSERT INTO USER_LEVEL VALUES(4,'User')});
    my $hash = '*' . uc(unpack('H*', sha1(sha1('fixture-right'))));
    my $id = 0;
    for my $name (qw(Alice Bob Carol Dave Eve Frank)) {
        $h->do('INSERT INTO USER VALUES(?,?,?,?,0,NULL)', undef, ++$id, $name, $hash, 4);
    }
    my $trace = {sql => [], binds => []};
    $h->{private_mb923} = $trace;
    my $b = bless {dbh => $h, logger => bless({}, 'MB923::Log'),
        irc => bless({}, 'MB923::IRC'), metrics => bless({values => {}}, 'MB923::Metrics'),
        notices => [], console => [], audit => []}, 'MB923::Bot';
    $b->{auth} = Mediabot::Auth->new(dbh => $h, logger => $b->{logger}, metrics => $b->{metrics});
    return ($b, $trace);
}
no warnings qw(redefine once);
local *Mediabot::LoginCommands::botNotice = sub {push @{$_[0]{notices}}, [$_[1],$_[2]]; 1};
local *Mediabot::LoginCommands::logBot = sub {push @{$_[0]{audit}}, [@_[3..$#_]]; 1};
sub attempt {
    my ($b, $trace, $nick, $args) = @_;
    $_ = [] for @$trace{qw(sql binds)};
    $b->{notices} = []; $b->{console} = []; $b->{audit} = [];
    my @warnings; local $SIG{__WARN__} = sub {push @warnings, @_};
    my $ret = Mediabot::LoginCommands::userLogin_ctx(bless {bot => $b, nick => $nick, args => $args}, 'MB923::Ctx');
    my $copy = JSON::PP->new->decode(JSON::PP->new->encode($b->{_login_failures} // {}));
    my $out = {return => $ret, failures => $copy, notices => $b->{notices},
        sql => [@{$trace->{sql}}], binds => [@{$trace->{binds}}],
        metrics => {%{$b->{metrics}{values}}}, console => $b->{console}, audit => $b->{audit},
        warnings => \@warnings, sessions => {%{$b->{auth}{sessions} // {}}},
        rows => $b->{dbh}->selectall_arrayref('SELECT id_user,nickname,auth,last_login FROM USER ORDER BY id_user'),
        hostmasks => $b->{dbh}->selectall_arrayref('SELECT id_user,hostmask FROM USER_HOSTMASK ORDER BY id_user')};
    # The old session objects are not mutated in these scenarios.
    return $out;
}
my %out;
for my $spec (['same','Alice','Alice'], ['casefold','ALICE','aLiCe'], ['unknown','Ghost','gHoSt'],
              ['distinct','Visitor','Alice']) {
    my ($label,$nick,$user) = @$spec;
    my ($b,$trace) = fixture();
    $out{series}{$label} = [map {attempt($b,$trace,$nick,[$user,'fixture-wrong'])} 1..6];
    $MB923::Clock::now += 59;
    $out{series}{$label.'_at59'} = attempt($b,$trace,$nick,[$user,'fixture-wrong']);
    $MB923::Clock::now++;
    $out{series}{$label.'_at60'} = attempt($b,$trace,$nick,[$user,'fixture-wrong']);
    $b->{dbh}->disconnect;
}
for my $kind (qw(account actor)) {
    my ($b,$trace) = fixture();
    my @users = qw(Alice Bob Carol Dave Eve Frank);
    my @series;
    for my $i (0..5) {
        push @series, attempt($b,$trace,$kind eq 'account' ? 'Visitor'.$i : 'Visitor',
            [$kind eq 'account' ? 'Alice' : $users[$i], 'fixture-wrong']);
    }
    $out{rotation}{$kind} = \@series;
    $b->{dbh}->disconnect;
}
for my $spec (['same_success','Alice','Alice',3,0], ['distinct_success','Visitor','Alice',3,0],
              ['prefixed','Alice','Alice',0,1], ['plain_success','Visitor','Alice',0,0]) {
    my ($label,$nick,$user,$bad,$prefixed) = @$spec;
    my ($b,$trace) = fixture();
    attempt($b,$trace,$nick,[$user,'fixture-wrong']) for 1..$bad;
    my @args = ($user,'fixture-right'); unshift @args,$nick if $prefixed;
    $out{success}{$label} = attempt($b,$trace,$nick,\@args);
    $b->{dbh}->disconnect;
}
{
    my ($b,$trace) = fixture();
    $b->{_login_failures}{old} = {ts => time()-121,count => 5};
    $b->{_login_failures}{recent} = {ts => time()-119,count => 2};
    $out{cleanup} = attempt($b,$trace,'Visitor',['Alice','fixture-wrong']);
    $b->{dbh}->disconnect;
}
for my $spec (['undef',undef], ['scalar','not an array'], ['hash',{}], ['empty',[]],
              ['missing_password',['Alice']], ['empty_password',['Alice','']]) {
    my ($b,$trace) = fixture();
    $out{invalid}{$spec->[0]} = attempt($b,$trace,'Visitor',$spec->[1]);
    $b->{dbh}->disconnect;
}
print JSON::PP->new->canonical->utf8->encode(\%out);
MB923_NATIVE
    open my $native, '-|', $^X, '-I.', '-It/lib', '-e', $probe
        or die "start native login-throttle probe: $!";
    my $output = do { local $/; <$native> };
    close $native;
    $assert->is($? >> 8, 0, 'native login-throttle probe completes');
    my $r = JSON::PP::decode_json($output);
    my $json = JSON::PP->new->canonical;
    my $blocked = 'Too many failed login attempts. Please wait 61 seconds.';
    my (@got, @want);
    for my $label (qw(same casefold unknown)) {
        my $key = $label eq 'unknown' ? 'ghost' : 'alice';
        my $failed = $label eq 'unknown' ? 'Login failed (Unknown user).' : 'Login failed (Bad password).';
        for my $i (0..5) {
            my $v = $r->{series}{$label}[$i];
            push @got, [$v->{failures}, $v->{notices}[0][1], scalar(@{$v->{sql}}),
                $v->{metrics}{mediabot_auth_failure_total}, $v->{warnings},
                [map {$_->[2]} @{$v->{rows}}], $v->{sessions}];
            my $n = $i < 5 ? $i+1 : 5;
            push @want, [{$key => {count => $n, ts => 2_000_000_000}},
                $i < 5 ? $failed : $blocked, $i == 5 ? 0 : $label eq 'unknown' ? 1 : 2,
                $n, [], [0,0,0,0,0,0], {}];
        }
    }
    $assert->is($json->encode(\@got), $json->encode(\@want),
        'same, casefolded and unknown identities count once; five failures are allowed and the sixth performs no SQL');
    (@got, @want) = ((), ());
    for my $label (qw(distinct account actor)) {
        my $series = $label eq 'distinct' ? $r->{series}{distinct} : $r->{rotation}{$label};
        for my $i (0..5) {
            my $v = $series->[$i];
            my %counts = map {$_ => $v->{failures}{$_}{count}} keys %{$v->{failures}};
            my %expected;
            if ($label eq 'distinct') {%expected = (alice => $i < 5 ? $i+1 : 5, visitor => $i < 5 ? $i+1 : 5)}
            elsif ($label eq 'account') {
                %expected = (alice => $i < 5 ? $i+1 : 5, map {('visitor'.$_) => 1} 0..($i < 5 ? $i : 4));
                $expected{visitor5} = 0 if $i == 5;
            } else {
                my @users = qw(alice bob carol dave eve frank);
                %expected = (visitor => $i < 5 ? $i+1 : 5, map {$users[$_] => 1} 0..($i < 5 ? $i : 4));
            }
            push @got, [\%counts, $v->{notices}[0][1], scalar(@{$v->{sql}}), $v->{warnings}];
            push @want, [\%expected, $i < 5 ? 'Login failed (Bad password).' : $blocked, $i < 5 ? 2 : 0, []];
        }
    }
    $assert->is($json->encode(\@got), $json->encode(\@want),
        'distinct identities retain both counters and neither nick rotation nor account rotation bypasses the limit');
    (@got, @want) = ((), ());
    for my $label (qw(same casefold unknown distinct)) {
        for my $age (59,60) {
            my $v = $r->{series}{$label.'_at'.$age};
            my @keys = $label eq 'unknown' ? ('ghost') : $label eq 'distinct' ? ('alice','visitor') : ('alice');
            my %expected = map {$_ => {count => $age == 59 ? 5 : 1,
                ts => $age == 59 ? 2_000_000_000 : 2_000_000_060}} @keys;
            my $failed = $label eq 'unknown' ? 'Login failed (Unknown user).' : 'Login failed (Bad password).';
            push @got, [$v->{failures},$v->{notices}[0][1],scalar(@{$v->{sql}}),$v->{warnings}];
            push @want, [\%expected, $age == 59
                ? 'Too many failed login attempts. Please wait 2 seconds.' : $failed,
                $age == 59 ? 0 : $label eq 'unknown' ? 1 : 2, []];
        }
    }
    $assert->is($json->encode(\@got), $json->encode(\@want),
        'the 60-second window still blocks at 59 seconds and starts one new failure at exactly 60');
    (@got, @want) = ((), ());
    for my $label (qw(same_success distinct_success prefixed plain_success)) {
        my $v = $r->{success}{$label};
        my $nick = $label eq 'same_success' || $label eq 'prefixed' ? 'Alice' : 'Visitor';
        my $session = $v->{sessions}{lc $nick} // {};
        my @writes = grep {$_->[0] =~ /^UPDATE USER SET auth=1|^INSERT INTO USER_HOSTMASK/} @{$v->{binds}};
        my $bad_hash = grep {$_->[0] eq 'UPDATE USER SET password = ? WHERE id_user = ?'
            && $_->[1] ne '<valid fixture hash>'} @{$v->{binds}};
        push @got, [$v->{return},$v->{failures},$v->{notices},$session->{id_user},$session->{irc_nick},
            [map {$_->[2]} @{$v->{rows}}],$v->{hostmasks},scalar(@writes),0+$bad_hash,$v->{warnings}];
        push @want, [1,{},[[$nick,'Login successful as Alice (Level: User)']],1,$nick,
            [1,0,0,0,0,0],[[1,'*ident@fixture.example']],2,0,[]];
    }
    my $cleanup = $r->{cleanup};
    push @got, $cleanup->{failures};
    push @want, {recent => {count=>2,ts=>1_999_999_881},alice=>{count=>1,ts=>2_000_000_000},
        visitor=>{count=>1,ts=>2_000_000_000}};
    for my $label (sort keys %{$r->{invalid}}) {
        my $v = $r->{invalid}{$label};
        push @got, [$v->{return},$v->{failures},$v->{sql},$v->{notices},$v->{warnings}];
        push @want, [undef,{},[],[['Visitor','Syntax error: /msg mediabot login <username> <password>']],[]];
    }
    $assert->is($json->encode(\@got), $json->encode(\@want),
        'real successful verification resets both keys, establishes the session and preserves cleanup and defensive argument handling');
};
