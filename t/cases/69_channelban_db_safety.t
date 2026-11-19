# t/cases/69_channelban_db_safety.t
# =============================================================================
# Static regression checks for Mediabot::ChannelBan DB safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_channelban_safety {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_channelban_safety {
    my ($src, $name) = @_;

    my $start = index($src, "sub $name");
    die "sub $name not found" if $start < 0;

    my $brace = index($src, "{", $start);
    die "opening brace for $name not found" if $brace < 0;

    my $depth      = 0;
    my $in_single  = 0;
    my $in_double  = 0;
    my $in_comment = 0;
    my $escape     = 0;

    for (my $i = $brace; $i < length($src); $i++) {
        my $c = substr($src, $i, 1);

        if ($in_comment) {
            $in_comment = 0 if $c eq "\n";
            next;
        }

        if ($in_single) {
            if ($c eq "\\" && !$escape) {
                $escape = 1;
                next;
            }

            if ($c eq "'" && !$escape) {
                $in_single = 0;
            }

            $escape = 0;
            next;
        }

        if ($in_double) {
            if ($c eq "\\" && !$escape) {
                $escape = 1;
                next;
            }

            if ($c eq '"' && !$escape) {
                $in_double = 0;
            }

            $escape = 0;
            next;
        }

        if ($c eq "#") {
            $in_comment = 1;
            next;
        }

        if ($c eq "'") {
            $in_single = 1;
            next;
        }

        if ($c eq '"') {
            $in_double = 1;
            next;
        }

        if ($c eq "{") {
            $depth++;
        }
        elsif ($c eq "}") {
            $depth--;

            if ($depth == 0) {
                return substr($src, $start, $i - $start + 1);
            }
        }
    }

    die "end of sub $name not found";
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_channelban_safety(File::Spec->catfile('.', 'Mediabot', 'ChannelBan.pm'));

    $assert->ok(
        $src =~ /sub _log/,
        'ChannelBan has _log helper'
    );

    for my $subname (qw(active_ban_for_mask add_ban list_active_bans mark_removed expired_bans)) {
        my $func = _extract_sub_channelban_safety($src, $subname);

        $assert->ok(
            $func =~ /unless \(\$sth\)/,
            "$subname handles prepare failure"
        );

        $assert->ok(
            $func =~ /SQL prepare error/,
            "$subname logs prepare failure"
        );

        $assert->ok(
            $func =~ /unless \(\$sth->execute/,
            "$subname handles execute failure"
        );

        $assert->ok(
            $func =~ /SQL execute error/,
            "$subname logs execute failure"
        );

        $assert->ok(
            $func =~ /\$sth->finish;\s*return/s,
            "$subname finishes statement before returning on execute failure"
        );
    }

    my $add = _extract_sub_channelban_safety($src, 'add_ban');
    $assert->ok(
        $add =~ /last_insert_id/,
        'add_ban uses DBI last_insert_id after successful insert'
    );

    $assert->ok(
        $add =~ /mysql_insertid/,
        'add_ban keeps mysql_insertid fallback'
    );

    my $mark = _extract_sub_channelban_safety($src, 'mark_removed');
    $assert->ok(
        $mark =~ /return \(0, "database prepare error"\)/,
        'mark_removed returns explicit prepare error'
    );

    $assert->ok(
        $mark =~ /return \(0, "database execute error"\)/,
        'mark_removed returns explicit execute error'
    );

    my $active = _extract_sub_channelban_safety($src, 'active_ban_for_mask');
    $assert->ok(
        $active =~ /return undef unless defined\(\$id_channel\)/,
        'active_ban_for_mask validates channel id input'
    );

    $assert->ok(
        $active =~ /return undef unless defined\(\$hostmask\)/,
        'active_ban_for_mask validates hostmask input'
    );

    # MB922: real DBI handles, the real connection-owner policy and the real
    # expiry pipeline. Keep reconnection and standalone API behaviour together.
    require JSON::PP;
    my $probe = <<'MB922_NATIVE';
use strict;
use warnings;
use utf8;
use DBI;
use File::Temp qw(tempdir);
use JSON::PP;
use Mediabot::DB;
use Mediabot::ChannelBan;
use Mediabot::Channel;
use Mediabot::Mediabot;
use Mediabot::ChannelCommands ();
use Mediabot::Context;
use MockUser;
use MockMessage;
{
    package MB922::DBI; our @ISA = ('DBI');
    package MB922::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($self, $sql, @rest) = @_;
        my $state = $self->{private_mb922};
        push @{$state->{sql}}, $sql if $state;
        if ($state && $state->{target_fault} && $sql =~ /SELECT\s+u\.id_user,/s
                && $state->{target_fault} eq 'prepare') {
            return $self->set_err(1, 'target permission prepare interrupted');
        }
        if ($state && ($state->{ban_fault} // '') eq 'prepare'
                && $sql =~ /FROM CHANNEL_BAN\b.*ORDER BY id_channel_ban DESC/s) {
            return $self->set_err(1, 'active ban prepare interrupted');
        }
        # Only this MariaDB interval expression needs a private dialect bridge.
        my $sqlite = $sql;
        $sqlite =~ s/\(NOW\(\) \+ INTERVAL \? SECOND\)/datetime(NOW(), ? || ' seconds')/g;
        my $sth = $self->SUPER::prepare($sqlite, @rest);
        $sth->{private_mb922} = {state => $state, sql => $sql} if $sth && $state;
        return $sth;
    }
    package MB922::DBI::st; our @ISA = ('DBI::st');
    sub execute {
        my ($self, @bind) = @_;
        my $p = $self->{private_mb922};
        push @{$p->{state}{binds}}, [$p->{sql}, @bind] if $p;
        if ($p && $p->{sql} =~ /SELECT\s+u\.id_user,/s
                && ($p->{state}{target_fault} // '') eq 'execute') {
            return $self->set_err(1, 'target permission execute interrupted');
        }
        if ($p && ($p->{state}{ban_fault} // '') eq 'execute'
                && $p->{sql} =~ /FROM CHANNEL_BAN\b.*ORDER BY id_channel_ban DESC/s) {
            return $self->set_err(1, 'active ban execute interrupted');
        }
        return $self->SUPER::execute(@bind);
    }
    sub fetchrow_hashref {
        my ($self, @args) = @_;
        my $p = $self->{private_mb922};
        if ($p && $p->{sql} =~ /SELECT\s+u\.id_user,/s
                && ($p->{state}{target_fault} // '') eq 'fetch') {
            return $self->set_err(1, 'target permission fetch interrupted');
        }
        if ($p && $p->{sql} =~ /FROM CHANNEL_BAN\b.*ORDER BY id_channel_ban DESC/s) {
            my $fault = $p->{state}{ban_fault} // '';
            my $seen = $p->{fetches}++;
            return $self->set_err(1, 'active ban fetch interrupted')
                if $fault eq 'fetch' || ($fault eq 'fetch_late' && $seen == 1);
        }
        return $self->SUPER::fetchrow_hashref(@args);
    }
    sub finish {
        my ($self) = @_;
        my $p = $self->{private_mb922};
        if ($p && $p->{sql} =~ /SELECT\s+u\.id_user,/s) {
            $p->{state}{target_finishes}++;
            $self->set_err(undef, undef); # cleanup must not erase a fetch failure
            die 'target permission finish interrupted' if ($p->{state}{target_fault} // '') eq 'finish';
        }
        if ($p && $p->{sql} =~ /FROM CHANNEL_BAN\b.*ORDER BY id_channel_ban DESC/s) {
            $self->set_err(undef, undef);
            die 'active ban finish interrupted' if ($p->{state}{ban_fault} // '') eq 'finish';
        }
        return $self->SUPER::finish;
    }
    package MB922::Log; sub log {1}
    package MB922::DB; our @ISA = ('Mediabot::DB');
    sub _connect {
        my ($self) = @_;
        $self->{connects}++;
        return undef if $self->{unavailable};
        my $dbh = DBI->connect('dbi:SQLite:dbname='.$self->{path}, '', '', {
            RootClass => 'MB922::DBI', RaiseError => 0, PrintError => 0,
            AutoCommit => 1, sqlite_unicode => 1});
        $dbh->sqlite_create_function('NOW', 0, sub {'2026-10-23 12:00:00'});
        $dbh->{private_mb922} = $self->{trace} if $self->{trace};
        return $self->{dbh} = $dbh;
    }
    package MB1368::Bot; our @ISA = ('MB922::Bot');
    sub get_user_from_message {$_[0]{actor}}
    package MB1368::Fullop;
    sub authorize_delegated_ban {my ($self, %args) = @_; push @{$self->{calls}}, \%args; 1}
    package MB922::IRC;
    sub nick_folded {'mediabot'}
    sub is_connected {1}
    sub do_NOTICE {my ($self, %args) = @_; push @{$self->{notices}}, \%args; 1}
    sub send_message {my ($s, @args) = @_; push @{$s->{sent}}, \@args; 1}
    package MB922::Bot; our @ISA = ('Mediabot');
    sub gethChannelsNicksOnChan {'mediabot'}
    package MB922::Metrics;
    sub inc {push @{$_[0]{events}}, $_[1]; 1}
}
$INC{'MB922/DBI.pm'} = __FILE__;
sub fixture {
    my ($legacy) = @_;
    my $dir = tempdir(CLEANUP => 1);
    my $db = bless {path => "$dir/ban.sqlite", logger => bless({}, 'MB922::Log')}, 'MB922::DB';
    my $h = $db->_connect;
    $h->do(q{CREATE TABLE CHANNEL_BAN(
        id_channel_ban INTEGER PRIMARY KEY AUTOINCREMENT, id_channel INTEGER,
        mask TEXT, ban_level INTEGER, reason TEXT, created_by INTEGER,
        created_by_nick TEXT, created_at TEXT DEFAULT '2026-10-23 12:00:00',
        expires_at TEXT, active INTEGER, source TEXT,
        removed_by INTEGER, removed_by_nick TEXT, removed_at TEXT, remove_reason TEXT)});
    for my $row (
        [10, 1, '*!*old@old.example', '2026-10-23 11:59:00', 1],
        [21, 1, 'spammer!*@host.example', '2026-10-23 12:10:00', 1],
        [35, 2, '*!*other@other.example', undef, 1],
        [77, 1, '*!*gone@gone.example', undef, 0]) {
        $h->do(q{INSERT INTO CHANNEL_BAN(id_channel_ban,id_channel,mask,expires_at,active,
            ban_level,reason,created_by,created_by_nick,source)
            VALUES(?,?,?,?,?,100,'fixture',1,'Alice','irc')}, undef, @$row);
    }
    my $trace = {sql => [], binds => []};
    $db->{trace} = $trace; $h->{private_mb922} = $trace;
    my $bot = bless {db => $db, dbh => $h, logger => $db->{logger},
        irc => bless({sent => []}, 'MB922::IRC'),
        channels => {'#test' => Mediabot::Channel->new({id => 1, name => '#test'})},
        metrics => bless({events => []}, 'MB922::Metrics')}, 'MB922::Bot';
    my $cb = Mediabot::ChannelBan->new(bot => $legacy ? undef : $bot, dbh => $h, logger => $db->{logger});
    $bot->{channel_ban} = $cb;
    return ($bot, $cb, $trace, $dir);
}
sub invoke {
    my ($cb, $kind) = @_;
    return $cb->active_ban_for_mask(1, 'spammer!~u@host.example') if $kind eq 'active';
    return [$cb->list_active_bans(1, 11)] if $kind eq 'list';
    return [$cb->expired_bans] if $kind eq 'expired';
    return [$cb->add_ban(id_channel => 1, mask => '*!*new@new.example', ban_level => 100,
        reason => 'été', created_by => 1, created_by_nick => 'Alice', expires_seconds => 600,
        source => 'irc')] if $kind eq 'add';
    return [$cb->mark_removed(id_channel => 1, selector => 21, removed_by => 1,
        removed_by_nick => 'Alice', remove_reason => 'manual')] if $kind eq 'remove';
    die 'unknown operation';
}
sub rows {
    my ($b) = @_;
    my $h = $b->{db}{dbh};
    return $h->selectall_arrayref('SELECT * FROM CHANNEL_BAN ORDER BY id_channel_ban', {Slice => {}});
}
my %out;
for my $state (qw(nominal reconnected self_reconnect unavailable legacy)) {
    for my $kind (qw(active list expired add remove)) {
        my ($b, $cb, $trace, $dir) = fixture($state eq 'legacy');
        my $old = $b->{dbh};
        if ($state eq 'reconnected') {
            $old->disconnect;
            $b->{dbh} = $b->{db}->ensure_connected;
            die 'fixture reconnect failed' unless $b->{dbh};
        } elsif ($state eq 'self_reconnect' || $state eq 'unavailable') {
            $old->disconnect;
            $b->{db}{unavailable} = 1 if $state eq 'unavailable';
        }
        my @warnings;
        local $SIG{__WARN__} = sub {push @warnings, @_};
        my $result = invoke($cb, $kind);
        $out{$state}{$kind} = {result => $result, sql => [@{$trace->{sql}}], binds => [@{$trace->{binds}}],
            rows => $state eq 'unavailable' ? undef : rows($b), warnings => \@warnings,
            cleared => !defined($cb->{dbh}) ? 1 : 0, connects => $b->{db}{connects}};
        $b->{db}{dbh}->disconnect if $b->{db}{dbh};
        delete $b->{channel_ban}; delete $cb->{bot};
    }
}
# A cached, still-live independent handle must not be a fallback during outage.
{
    my ($b, $cb, $trace, $dir) = fixture();
    my $old = $b->{dbh};
    $b->{db}{dbh} = undef; $b->{db}{unavailable} = 1;
    my $result = invoke($cb, 'remove');
    $out{stale_live} = {result => $result, cleared => !defined($cb->{dbh}) ? 1 : 0,
        sql => [@{$trace->{sql}}], active => scalar($old->selectrow_array('SELECT active FROM CHANNEL_BAN WHERE id_channel_ban=21'))};
    $old->disconnect; delete $b->{channel_ban}; delete $cb->{bot};
}
# Recover the same helper after an outage, then use the real expiry pipeline.
{
    my ($b, $cb, $trace, $dir) = fixture();
    $b->{dbh}->disconnect; $b->{db}{unavailable} = 1;
    local $SIG{__WARN__} = sub {};
    invoke($cb, 'active');
    $b->{db}{unavailable} = 0;
    $b->{dbh} = $b->{db}->ensure_connected;
    my $count = $b->process_expired_channel_bans;
    $out{expiry_recovery} = {count => $count, sent => $b->{irc}{sent}, metrics => $b->{metrics}{events},
        rows => rows($b)};
    $b->{dbh}->disconnect; delete $b->{channel_ban}; delete $cb->{bot};
}

# MB1103: call the real parser and INSERT path, including the SQL expiry.
{
    my $cb=bless {},'Mediabot::ChannelBan';
    my @input=('10m','0002H','35791394','596523h','24855d','3550w',
        ('0'x350).'10m','35791395m','596524h','24856d','3551w',
        ('9'x32).'w',('9'x309).'h');
    $out{duration_parse}=[map {my @v=$cb->parse_duration($_);$v[0]="$v[0]" if defined($v[0]);\@v} @input];
}
for my $raise (0,1) {
    for my $value (1,600,2147483647,'00010',0,'0000',undef,
            2147483648,('9'x309),'Inf','NaN','1e3',-1,'',1.5,[],{},"10\n") {
        my ($b,$cb,$trace,$dir)=fixture();$b->{dbh}{RaiseError}=$raise;
        my @warnings;local $SIG{__WARN__}=sub {push @warnings,@_};
        my @result=$cb->add_ban(id_channel=>1,mask=>'*!*new@new.example',
            ban_level=>100,expires_seconds=>$value,source=>'irc');
        my @inserts=grep {$_->[0]=~/INSERT INTO CHANNEL_BAN/} @{$trace->{binds}};
        my $expiry=$b->{dbh}->selectcol_arrayref('SELECT expires_at FROM CHANNEL_BAN WHERE id_channel_ban=78');
        push @{$out{duration_store}},[\@result,scalar(@{rows($b)}),\@inserts,$expiry,\@warnings];
        # A rejected API value must not poison the same helper's next request.
        if (@result && defined($result[1])) {
            my @next=$cb->add_ban(id_channel=>1,mask=>'*!*next@next.example',
                ban_level=>100,expires_seconds=>600,source=>'irc');
            push @{$out{duration_recovery}},[\@next,
                $b->{dbh}->selectcol_arrayref('SELECT expires_at FROM CHANNEL_BAN WHERE id_channel_ban=78')];
        }
        $b->{dbh}->disconnect;delete $b->{channel_ban};delete $cb->{bot};
    }
}
# MB1368: the real command, hierarchy SELECT and persistent ban writes.
# Fail only the target-level query; actor permission/history/storage stay live.
for my $raise (0, 1) {
    for my $command (qw(ban kickban kb)) {
        for my $private (0, 1) {
            for my $state (qw(higher equal lower zero no_membership unknown other_channel mask
                             prepare execute fetch finish unauthenticated actor_low
                             ban_prepare ban_execute ban_fetch ban_fetch_late ban_finish)) {
                my ($b, $cb, $trace, $dir) = fixture();
                bless $b, 'MB1368::Bot';
                my $h = $b->{dbh};
                $h->do('CREATE TABLE USER(id_user INTEGER, nickname TEXT)');
                $h->do('CREATE TABLE CHANNEL(id_channel INTEGER, name TEXT)');
                $h->do('CREATE TABLE USER_CHANNEL(id_user INTEGER, id_channel INTEGER, level INTEGER)');
                $h->do('CREATE TABLE CHANNEL_LOG(id_channel_log INTEGER, id_channel INTEGER, nick TEXT, userhost TEXT, ts TEXT)');
                $h->do('CREATE TABLE ACTIONS_LOG(ts TEXT, id_user INTEGER, id_channel INTEGER, hostmask TEXT, action TEXT, args TEXT)');
                $h->do("INSERT INTO USER VALUES(1,'Alice')");
                $h->do("INSERT INTO USER VALUES(2,'Target')") unless $state eq 'unknown';
                $h->do("INSERT INTO CHANNEL VALUES(1,'#test'),(2,'#other')");
                $h->do('INSERT INTO USER_CHANNEL VALUES(1,1,?)', undef, $state eq 'actor_low' ? 74 : 100);
                unless ($state eq 'unknown' || $state eq 'no_membership') {
                    my $level = $state =~ /^ban_/ ? 0 : $state eq 'equal' ? 100 : $state eq 'lower' ? 50 : $state eq 'zero' ? 0 : 150;
                    $h->do('INSERT INTO USER_CHANNEL VALUES(2,?,?)', undef, $state eq 'other_channel' ? 2 : 1, $level);
                }
                $h->do("INSERT INTO CHANNEL_LOG VALUES(1,1,'Target','Target!ident\@target.example','2026-10-23 12:00:00')");
                $b->{actor} = MockUser->new(id => 1, nick => 'Alice', level => 'User', auth => $state ne 'unauthenticated');
                $b->{fullop} = bless {calls => []}, 'MB1368::Fullop';
                $h->{RaiseError} = $raise;
                $trace->{target_fault} = $state if $state =~ /^(?:prepare|execute|fetch|finish)$/;
                $trace->{target_fault} = 'prepare' if $state eq 'mask'; # explicit masks do not query nick levels
                $trace->{ban_fault} = $1 if $state =~ /^ban_(.+)$/;
                $trace->{sql} = []; $trace->{binds} = [];
                my $target = $state eq 'mask' ? '*!ident@target.example' : 'Target';
                my @args = ($private ? '#test' : (), $target, '10m', '75', 'fixture');
                my $ctx = Mediabot::Context->new(bot => $b, nick => 'Alice',
                    channel => $private ? 'mediabot' : '#test', command => $command, args => \@args,
                    message => MockMessage->new(prefix => 'Alice!u@actor.example'));
                my $call = sub {
                    my @warnings; local $SIG{__WARN__} = sub {push @warnings, @_};
                    my $ok = eval {
                        $command eq 'ban' ? Mediabot::ChannelCommands::channelBan_ctx($ctx)
                                         : Mediabot::ChannelCommands::channelKickBan_ctx($ctx);
                        1;
                    };
                    my @level_reads = map {[@{$_}[1..$#$_]]}
                        grep {$_->[0] =~ /SELECT\s+u\.id_user,/s} @{$trace->{binds}};
                    return {ok => $ok ? 1 : 0, warnings => \@warnings,
                        notices => $b->{irc}{notices} || [], sent => $b->{irc}{sent},
                        stored => $h->selectall_arrayref('SELECT id_channel,mask,ban_level,expires_at FROM CHANNEL_BAN WHERE id_channel_ban>77'),
                        audit => $h->selectcol_arrayref('SELECT action FROM ACTIONS_LOG'),
                        delegated => scalar(@{$b->{fullop}{calls}}), level_reads => \@level_reads};
                };
                my $result = $call->();
                push @{$out{target_guard}}, [$raise, $command, $private, $state, $result];
                if ($state =~ /^(?:prepare|execute|fetch|finish)$/) {
                    # Same helper and DB handle: recovery must restore hierarchy refusal.
                    $trace->{target_fault} = '';
                    $b->{irc}{notices} = []; $b->{irc}{sent} = [];
                    my $recovered = $call->();
                    push @{$out{target_recovery}}, $recovered;
                }
                $h->disconnect; delete $b->{channel_ban}; delete $cb->{bot};
            }
        }
    }
}
# MB1369: duplicate prevention must never convert a read error into an INSERT.
for my $raise (0, 1) {
    for my $fault (qw(prepare execute fetch fetch_late finish)) {
        for my $existing (0, 1) {
            my ($b, $cb, $trace, $dir) = fixture();
            my $h = $b->{dbh}; $h->{RaiseError} = $raise;
            my $before = rows($b);
            my $mask = $existing ? '*!*old@old.example' : '*!*new@new.example';
            $trace->{ban_fault} = $fault;
            my (@result, @warnings);
            local $SIG{__WARN__} = sub {push @warnings, @_};
            my $ok = eval {@result = $cb->add_ban(id_channel => 1, mask => $mask,
                ban_level => 75, expires_seconds => 600); 1};
            my $unchanged = JSON::PP->new->canonical->encode(rows($b)) eq JSON::PP->new->canonical->encode($before);
            my @inserts = grep {$_->[0] =~ /INSERT INTO CHANNEL_BAN/} @{$trace->{binds}};
            $trace->{ban_fault} = '';
            my @recovery = $cb->add_ban(id_channel => 1, mask => $mask, ban_level => 75, expires_seconds => 600);
            push @{$out{duplicate_guard}}, [$raise, $fault, $existing, $ok ? 1 : 0,
                \@result, \@warnings, $unchanged ? 1 : 0, scalar(@inserts), \@recovery];
            $h->disconnect; delete $b->{channel_ban}; delete $cb->{bot};
        }
    }
}
print JSON::PP->new->canonical->utf8->encode(\%out);
MB922_NATIVE
    open my $native, '-|', $^X, '-I.', '-It/lib', '-e', $probe
        or die "start native ChannelBan reconnect probe: $!";
    my $output = do { local $/; <$native> };
    close $native;
    $assert->is($? >> 8, 0, 'native ChannelBan lifecycle probe completes');
    my $r = JSON::PP::decode_json($output);
    my $json = JSON::PP->new->canonical;
    my (@nominal, @expected_nominal, @reconnected, @expected_reconnected);
    for my $style (qw(nominal legacy)) {
        for my $kind (qw(active list expired add remove)) {
            my $v = $r->{$style}{$kind};
            my $result = $kind eq 'active' ? $v->{result}{id_channel_ban}
                : $kind eq 'list' || $kind eq 'expired'
                    ? [map {$_->{id_channel_ban}} @{$v->{result}}] : $v->{result};
            my $expected = $kind eq 'active' ? 21 : $kind eq 'list' ? [10,21]
                : $kind eq 'expired' ? [10] : $kind eq 'add' ? [78,undef] : [1,undef];
            my @rows = map {[@{$_}{qw(id_channel_ban active)}]} @{$v->{rows}};
            my @expected_rows = ([10,1],[21,$kind eq 'remove' ? 0 : 1],[35,1],[77,0]);
            push @expected_rows, [78,1] if $kind eq 'add';
            push @nominal, [$result, \@rows, $v->{warnings}, $v->{cleared}, $v->{connects}];
            push @expected_nominal, [$expected, \@expected_rows, [], 0, 1];
        }
    }
    $assert->is($json->encode(\@nominal), $json->encode(\@expected_nominal),
        'all five operations retain native DB results and standalone dbh-only behaviour');
    for my $style (qw(reconnected self_reconnect)) {
        for my $kind (qw(active list expired add remove)) {
            my $v = $r->{$style}{$kind};
            push @reconnected, [@$v{qw(result rows sql binds warnings cleared connects)}];
            push @expected_reconnected, [@{$r->{nominal}{$kind}}{qw(result rows sql binds warnings)}, 0, 2];
        }
    }
    $assert->is($json->encode(\@reconnected), $json->encode(\@expected_reconnected),
        'bot and helper initiated reconnections restore all five real SQL operations with unchanged binds and rows');
    my (@outage, @expected_outage);
    for my $kind (qw(active list expired add remove)) {
        my $v = $r->{unavailable}{$kind};
        my $expected = $kind eq 'active' ? undef : $kind eq 'add' ? [undef,'no database handle']
            : $kind eq 'remove' ? [0,'no database handle'] : [];
        push @outage, [@$v{qw(result cleared sql warnings)}];
        push @expected_outage, [$expected,1,[],[]];
    }
    push @outage, $r->{stale_live};
    push @expected_outage, {result => [0,'no database handle'], cleared => 1, sql => [], active => 1};
    $assert->is($json->encode(\@outage), $json->encode(\@expected_outage),
        'outage clears the old handle, preserves return contracts and never writes through a stale live fallback');
    my $expiry = $r->{expiry_recovery};
    my @expired_rows = map {[@{$_}{qw(id_channel_ban active removed_by_nick remove_reason)}]} @{$expiry->{rows}};
    $assert->is($json->encode([$expiry->{count}, $expiry->{sent}, $expiry->{metrics}, \@expired_rows]),
        $json->encode([1, [['MODE',undef,'#test','-b','*!*old@old.example']],
            ['mediabot_channel_bans_expired_total'],
            [[10,0,'system','expired'],[21,1,undef,undef],[35,1,undef,undef],[77,0,undef,undef]]]),
        'the same helper recovers after outage and the real expiry pipeline removes only the due ban');
    # One assertion per boundary, preserving exact native SQL/wire evidence.
    my (%guard, %wanted_guard);
    for my $entry (@{$r->{target_guard}}) {
        my ($raise, $command, $private, $state, $v) = @$entry;
        my $fault = $state =~ /^(?:prepare|execute|fetch|finish)$/;
        my $allowed = $state =~ /^(?:lower|zero|no_membership|unknown|other_channel|mask)$/;
        my $mask = $state eq 'mask' ? '*!ident@target.example' : '*!*ident@target.example';
        my @wire = $allowed ? (['MODE',undef,'#test','+b',$mask]) : ();
        push @wire, ['KICK',undef,'#test','Target','(Alice) fixture']
            if $allowed && $command ne 'ban' && $state ne 'mask';
        my @notices = $state =~ /^ban_/ ? ('Cannot verify existing channel bans; ban cancelled.')
            : $fault ? ('Cannot verify target channel level; ban cancelled.')
            : $state eq 'unauthenticated' ? ('You must be logged to use this command.')
            : $state eq 'actor_low' ? ('Your channel level on #test must be at least 75 to use ban commands.')
            : !$allowed ? ('Refusing to ban Target: target channel level (' . ($state eq 'equal' ? 100 : 150) . ') is >= your level (100).')
            : ("Ban #78 added on #test: $mask level=75 duration=10m reason=fixture");
        push @notices, 'Kick skipped: target is a mask, not a nick.' if $allowed && $state eq 'mask' && $command ne 'ban';
        my @audit = $allowed ? ('ban') : ();
        push @audit, 'kickban' if $allowed && $command ne 'ban' && $state ne 'mask';
        my $skip_read = $state =~ /^(?:mask|unauthenticated|actor_low|prepare)$/;
        push @{$guard{$state}}, $v;
        push @{$wanted_guard{$state}}, {ok => 1, warnings => [],
            notices => [map {{target=>'Alice', text=>$_}} @notices], sent => \@wire,
            stored => $allowed ? [[1,$mask,75,'2026-10-23 12:10:00']] : [],
            audit => \@audit, delegated => $allowed ? 1 : 0,
            level_reads => $skip_read ? [] : [['#test','Target']]};
    }
    for my $state (sort keys %guard) {
        $assert->is($json->encode($guard{$state}), $json->encode($wanted_guard{$state}),
            "native ban/kickban/kb target hierarchy: $state on public/private routes with RaiseError off/on");
    }
    my @recovery = map {[@{$_}{qw(ok warnings notices sent stored audit delegated)}]} @{$r->{target_recovery}};
    $assert->is($json->encode(\@recovery), $json->encode([map {[1,[],
        [{target=>'Alice',text=>'Refusing to ban Target: target channel level (150) is >= your level (100).'}],
        [],[],[],0]} @recovery]), 'target permission recovery on the same DB handle preserves the higher-level ban refusal');
    my (@duplicate_guard, @wanted_duplicate_guard);
    for my $v (@{$r->{duplicate_guard}}) {
        my ($raise, $fault, $existing) = @$v;
        push @duplicate_guard, [@{$v}[3..$#$v]];
        push @wanted_duplicate_guard, [1,[undef,'Cannot verify existing channel bans; ban cancelled.'],[],1,0,
            $existing ? [undef,'an active ban already exists for *!*old@old.example (id 10)'] : [78,undef]];
    }
    $assert->is($json->encode(\@duplicate_guard), $json->encode(\@wanted_duplicate_guard),
        'native duplicate read failures preserve every ban row and skip INSERT; recovery restores existing-ban refusal or genuine new insertion');
    my $limit_error='duration exceeds maximum of 2147483647 seconds; use perm for a permanent ban';
    $assert->is($json->encode($r->{duration_parse}),$json->encode([
        ['600','10m',undef],['7200','2h',undef],['2147483640','35791394m',undef],
        ['2147482800','596523h',undef],['2147472000','24855d',undef],['2147040000','3550w',undef],
        ['600','10m',undef],map {[undef,undef,$limit_error]} 1..6]),
        'native duration parsing preserves units/leading zeros and rejects huge or out-of-range values before numeric coercion');
    my @wanted;
    for (0,1) {
        for my $seconds (1,600,2147483647,10,undef,undef,undef) {
            my $date=!defined($seconds)?undef:$seconds==1?'2026-10-23 12:00:01'
                :$seconds==600?'2026-10-23 12:10:00':$seconds==10?'2026-10-23 12:00:10':'2094-11-10 15:14:07';
            # SQL text is already checked independently; bind six owns expiry.
            push @wanted,[[78,undef],5,$seconds,[$date],[]];
        }
        push @wanted,map {[[undef,'invalid ban duration: expected 0 to 2147483647 whole seconds'],4,undef,[],[]]} 1..11;
    }
    my @stored=map {[$_->[0],$_->[1],@{$_->[2]}?$_->[2][0][7]:undef,$_->[3],$_->[4]]} @{$r->{duration_store}};
    $assert->is($json->encode([\@stored,$r->{duration_recovery}]),$json->encode([
        \@wanted,[map {[[78,undef],['2026-10-23 12:10:00']]} 1..22]]),
        'native INSERT never turns invalid seconds into permanent rows; explicit permanence, exact SQL expiry and recovery work with RaiseError on/off');

};
