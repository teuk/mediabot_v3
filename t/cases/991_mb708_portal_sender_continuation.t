# t/cases/991_mb708_portal_sender_continuation.t
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

    my $now = 5_000;
    my @sent;
    my $sender = Mediabot::Spark::Sender->new(
        clock => sub { $now },
        send_cb => sub { push @sent, [ @_ ]; return 1; },
    );
    $sender->arm();

    my $state = {
        enabled => 1, runtime_active => 1, irc_connected => 1,
        channel_joined => 1, flood_suppressed => 0,
        game_active => 0, wit_pending => 0,
        current_generation => 41,
    };
    my $open = {
        action => 'ready', reason => 'generated', kind => 'portal',
        content => { line => 'Trois personnes, un ingrédient absurde chacune.' },
    };
    my $close = {
        action => 'ready', reason => 'generated', kind => 'portal',
        content => { line => 'La théière syndiquée plaide non coupable devant le dragon.' },
    };

    my $opened = $sender->attempt_send(
        channel => '#spark', kind => 'portal', generation => 41,
        generated => $open, state_cb => sub { return { %$state } },
    );
    $assert->is($opened->{action}, 'sent',
        'mb708-991: Portal opener uses the ordinary guarded sender path');
    $assert->is($opened->{continuation}, 0,
        'mb708-991: ordinary delivery is never mislabeled as a continuation');

    $now += 5;
    my $ordinary_second = $sender->attempt_send(
        channel => '#spark', kind => 'portal', generation => 41,
        generated => $close, state_cb => sub { return { %$state } },
    );
    $assert->is($ordinary_second->{reason}, 'rate_limited',
        'mb708-991: global 120-second pacing remains unchanged');

    my $wrong_generation = $sender->attempt_send(
        channel => '#spark', kind => 'portal', generation => 40,
        continuation => 1, generated => $close,
        state_cb => sub { return { %$state } },
    );
    $assert->is($wrong_generation->{reason}, 'continuation_unavailable',
        'mb708-991: another generation cannot borrow the Portal continuation');

    my $not_portal = $sender->attempt_send(
        channel => '#other', kind => 'fork', generation => 41,
        continuation => 1,
        generated => {
            action => 'ready', kind => 'fork',
            content => { question => 'A ou B ?', a => 'A', b => 'B' },
        },
        state_cb => sub { return { %$state } },
    );
    $assert->is($not_portal->{reason}, 'invalid_continuation',
        'mb708-991: only Portal may request the bounded continuation path');

    my $flooded = $sender->attempt_send(
        channel => '#spark', kind => 'portal', generation => 41,
        continuation => 1, generated => $close,
        state_cb => sub { return { %$state, flood_suppressed => 1 } },
    );
    $assert->is($flooded->{reason}, 'flood_suppressed',
        'mb708-991: flood truth still wins at final Portal delivery');
    $assert->is(scalar(@sent), 1,
        'mb708-991: a blocked continuation never reaches IRC transport');

    my $closed = $sender->attempt_send(
        channel => '#spark', kind => 'portal', generation => 41,
        continuation => 1, generated => $close,
        state_cb => sub { return { %$state } },
    );
    $assert->is($closed->{action}, 'sent',
        'mb708-991: same-event Portal synthesis may bypass pacing exactly once');
    $assert->is($closed->{continuation}, 1,
        'mb708-991: successful Portal continuation is explicit in metadata');
    $assert->is(scalar(@sent), 2,
        'mb708-991: opener and payoff are the only two IRC deliveries');

    my $repeated = $sender->attempt_send(
        channel => '#spark', kind => 'portal', generation => 41,
        continuation => 1, generated => $close,
        state_cb => sub { return { %$state } },
    );
    $assert->is($repeated->{reason}, 'continuation_unavailable',
        'mb708-991: Portal continuation cannot be replayed');

    my $log = Mediabot::Spark::Sender::format_sender_log('#spark', $closed);
    $assert->like($log, qr/continuation=1/,
        'mb708-991: sender log records the bounded continuation decision');
    $assert->unlike($log, qr/théière|dragon|coupable/i,
        'mb708-991: continuation logs remain content-free');

    $now += 121;
    $state->{current_generation} = 42;
    my $next_open = $sender->attempt_send(
        channel => '#spark', kind => 'portal', generation => 42,
        generated => $open, state_cb => sub { return { %$state } },
    );
    $assert->is($next_open->{action}, 'sent',
        'mb708-991: later Portal events still use normal pacing');

    $now += 121;
    my $expired = $sender->attempt_send(
        channel => '#spark', kind => 'portal', generation => 42,
        continuation => 1, generated => $close,
        state_cb => sub { return { %$state } },
    );
    $assert->is($expired->{reason}, 'continuation_unavailable',
        'mb708-991: continuation authority expires instead of becoming a general bypass');
};
