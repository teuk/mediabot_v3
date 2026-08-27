# t/cases/963_mb703_spark_sender_guarded_delivery.t
use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Spark::Sender;

return sub {
    my ($assert) = @_;

    my $now = 1000;
    my @sent;
    my $sender = Mediabot::Spark::Sender->new(
        clock => sub { $now },
        send_cb => sub { push @sent, [ @_ ]; return 1; },
    );

    my $generated = {
        action => 'ready', kind => 'fork',
        content => { question => 'Tea or chaos?', a => 'Tea', b => 'Chaos' },
    };

    my $state = {
        enabled => 1, runtime_active => 1, irc_connected => 1,
        channel_joined => 1, game_active => 0, wit_pending => 0,
        current_generation => 7,
    };

    my $off = $sender->attempt_send(
        channel => '#spark', kind => 'fork', generation => 7,
        generated => $generated, state_cb => sub { return { %$state } },
    );
    $assert->is($off->{reason}, 'kill_switch',
        'mb703-963: Spark sender starts fail-closed behind the master switch');
    $assert->is(scalar(@sent), 0,
        'mb703-963: disarmed sender never reaches IRC transport');

    $sender->arm();
    my $stale = $sender->attempt_send(
        channel => '#spark', kind => 'fork', generation => 6,
        generated => $generated, state_cb => sub { return { %$state } },
    );
    $assert->is($stale->{reason}, 'stale_generation',
        'mb703-963: late generation is rejected immediately before delivery');
    $assert->is(scalar(@sent), 0,
        'mb703-963: stale generation never reaches IRC transport');

    my $blocked = $sender->attempt_send(
        channel => '#spark', kind => 'fork', generation => 7,
        generated => $generated,
        state_cb => sub { return { %$state, game_active => 1 } },
    );
    $assert->is($blocked->{reason}, 'game_active',
        'mb703-963: live game gate wins at final delivery boundary');

    my $ok = $sender->attempt_send(
        channel => '#spark', kind => 'fork', generation => 7,
        generated => $generated, state_cb => sub { return { %$state } },
    );
    $assert->is($ok->{action}, 'sent',
        'mb703-963: fully authorized armed candidate can be delivered');
    $assert->is(scalar(@sent), 1,
        'mb703-963: exactly one IRC transport call occurs');
    $assert->like($sent[0][1], qr/Tea or chaos\?.*A\) Tea.*B\) Chaos/,
        'mb703-963: Fork renders all generated fields to one compact IRC line');

    my $limited = $sender->attempt_send(
        channel => '#spark', kind => 'fork', generation => 7,
        generated => $generated, state_cb => sub { return { %$state } },
    );
    $assert->is($limited->{reason}, 'rate_limited',
        'mb703-963: sender has an independent per-channel delivery limiter');
    $assert->is(scalar(@sent), 1,
        'mb703-963: rate limit does not touch IRC transport');

    my $log = Mediabot::Spark::Sender::format_sender_log('#spark', $ok);
    $assert->like($log, qr/^\[SPARK_SEND\] channel=#spark action=sent reason=delivered /,
        'mb703-963: delivery logging is metadata-only');
    $assert->unlike($log, qr/Tea|Chaos/,
        'mb703-963: generated content is absent from sender logs');
};
