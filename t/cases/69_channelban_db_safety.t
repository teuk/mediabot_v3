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
{
    package MB922::DBI; our @ISA = ('DBI');
    package MB922::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($self, $sql, @rest) = @_;
        my $state = $self->{private_mb922};
        push @{$state->{sql}}, $sql if $state;
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
        return $self->SUPER::execute(@bind);
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
    package MB922::IRC;
    sub nick_folded {'mediabot'}
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
};
