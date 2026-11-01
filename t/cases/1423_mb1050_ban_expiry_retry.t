use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use Mediabot::Mediabot;
use Mediabot::ChannelBan;
use Mediabot::Channel;

{
    package MB1050::Log;
    sub log {push @{$_[0]{rows}}, $_[2]; 1}
    package MB1050::Metrics;
    sub inc {push @{$_[0]{events}}, $_[1]; 1}
    package MB1050::IRC;
    sub is_connected {die "connection state unavailable\n" if $_[0]{state_error}; $_[0]{connected}}
    sub nick_folded {'mediabot'}
    sub send_message {
        my ($self, @args) = @_;
        die "transport unavailable\n" if $self->{send_error};
        $self->{before_send}->() if $self->{before_send};
        push @{$self->{sent}}, \@args;
        return 1;
    }
    package MB1050::Bans;
    our @ISA = ('Mediabot::ChannelBan');
    sub mark_removed {
        my ($self, %args) = @_;
        return (0, 'database execute error') if $self->{write_error};
        return ('0E0', undef) if $self->{zero_rows};
        return $self->SUPER::mark_removed(%args);
    }
}

sub fixture_1423 {
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '',
        {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->sqlite_create_function('NOW', 0, sub {'2026-10-31 23:00:00'});
    $dbh->do(q{CREATE TABLE CHANNEL_BAN(
        id_channel_ban INTEGER PRIMARY KEY, id_channel INTEGER, mask TEXT,
        ban_level INTEGER, reason TEXT, created_by INTEGER, created_by_nick TEXT,
        created_at TEXT, expires_at TEXT, active INTEGER, source TEXT,
        removed_by INTEGER, removed_by_nick TEXT, removed_at TEXT, remove_reason TEXT)});
    for my $row (
        [1, 10, '*!*one@host.example', '2026-10-31 22:59:00', 1],
        [2, 20, '*!*two@other.example', '2026-10-31 22:59:00', 1],
        [3, 10, '*!*future@host.example', '2026-11-01 01:00:00', 1],
        [4, 10, '*!*permanent@host.example', undef, 1],
        [5, 10, '*!*removed@host.example', '2026-10-31 22:59:00', 0]) {
        $dbh->do(q{INSERT INTO CHANNEL_BAN
            (id_channel_ban,id_channel,mask,expires_at,active,ban_level,source)
            VALUES(?,?,?,?,?,100,'irc')}, undef, @$row);
    }
    my $bot = bless {
        dbh => $dbh,
        logger => bless({rows => []}, 'MB1050::Log'),
        metrics => bless({events => []}, 'MB1050::Metrics'),
        irc => bless({connected => 1, sent => []}, 'MB1050::IRC'),
        channels => {
            '#one' => Mediabot::Channel->new({id => 10, name => '#one'}),
            '#two' => Mediabot::Channel->new({id => 20, name => '#two'}),
        },
        hChannelsNicks => {'#one' => ['alice'], '#two' => ['bob']},
    }, 'Mediabot';
    $bot->{channel_ban} = MB1050::Bans->new(dbh => $dbh, logger => $bot->{logger});
    return $bot;
}
sub active_1423 {
    return $_[0]{dbh}->selectcol_arrayref(
        'SELECT id_channel_ban FROM CHANNEL_BAN WHERE active=1 ORDER BY id_channel_ban');
}
sub release_1423 {
    my ($bot) = @_;
    $bot->{dbh}->disconnect;
    delete $bot->{channel_ban};
}

my @warnings;
local $SIG{__WARN__} = sub {push @warnings, @_};
{
    my $b = fixture_1423();
    is($b->process_expired_channel_bans, 0, 'absence from both channels defers expiration');
    is_deeply(active_1423($b), [1,2,3,4], 'expired bans stay active in SQL until IRC removal can be sent');
    is_deeply($b->{irc}{sent}, [], 'absence never emits a MODE to an unjoined channel');
    is_deeply($b->{metrics}{events}, [], 'deferred bans do not increase the expiration counter');
    $b->{hChannelsNicks}{'#ONE'} = ['MeDiAbOt'];
    delete $b->{hChannelsNicks}{'#one'};
    my @active_at_send;
    $b->{irc}{before_send} = sub {push @active_at_send, active_1423($b)};
    is($b->process_expired_channel_bans, 1, 'the next tick retries the joined channel independently');
    is_deeply($b->{irc}{sent}, [['MODE',undef,'#one','-b','*!*one@host.example']],
        'retry sends the exact original mask to the original channel');
    is_deeply(\@active_at_send, [[1,2,3,4]], 'SQL is changed only after the IRC dispatch');
    is_deeply(active_1423($b), [2,3,4], 'other-channel, permanent and future bans are preserved');
    my $removed = $b->{dbh}->selectrow_arrayref(q{SELECT removed_by_nick,remove_reason,removed_at
        FROM CHANNEL_BAN WHERE id_channel_ban=1});
    is_deeply($removed, ['system','expired','2026-10-31 23:00:00'], 'normal removal audit fields are retained');
    $b->{hChannelsNicks}{'#two'} = ['mediabot'];
    is($b->process_expired_channel_bans, 1, 'a later join recovers the second pending expiration');
    is($b->process_expired_channel_bans, 0, 'a completed expiration is not repeated');
    is_deeply($b->{metrics}{events}, [('mediabot_channel_bans_expired_total') x 2],
        'exactly the two completed removals are counted');
    release_1423($b);
}
for my $state (qw(disconnected state_error)) {
    my $b = fixture_1423();
    $b->{hChannelsNicks} = {'#one' => ['mediabot'], '#two' => ['mediabot']};
    $b->{irc}{connected} = 0 if $state eq 'disconnected';
    $b->{irc}{state_error} = 1 if $state eq 'state_error';
    is($b->process_expired_channel_bans, 0, "$state refuses expiration despite a stale nick list");
    is_deeply([$b->{irc}{sent}, active_1423($b), $b->{metrics}{events}],
        [[],[1,2,3,4],[]], "$state preserves IRC, SQL and counters");
    delete $b->{irc}{state_error}; $b->{irc}{connected} = 1;
    is($b->process_expired_channel_bans, 2, "$state recovers on the next connected tick");
    release_1423($b);
}
for my $failure (qw(send_error write_error zero_rows)) {
    my $b = fixture_1423();
    $b->{hChannelsNicks}{'#one'} = ['mediabot'];
    my $owner = $failure eq 'send_error' ? $b->{irc} : $b->{channel_ban};
    $owner->{$failure} = 1;
    is($b->process_expired_channel_bans, 0, "$failure cannot report a completed expiration");
    is_deeply([active_1423($b), $b->{metrics}{events}], [[1,2,3,4],[]],
        "$failure preserves pending bans and success counters");
    delete $owner->{$failure};
    is($b->process_expired_channel_bans, 1, "$failure is retried after recovery");
    release_1423($b);
}
{
    my $b = fixture_1423();
    delete $b->{channels}{'#one'};
    $b->{hChannelsNicks}{'#two'} = ['mediabot'];
    is($b->process_expired_channel_bans, 1, 'one unknown channel does not prevent other expirations');
    is_deeply(active_1423($b), [1,3,4], 'the unknown-channel ban remains pending');
    release_1423($b);
}
is_deeply(\@warnings, [], 'normal, deferred and failed expiry paths are warning-free');
done_testing;
