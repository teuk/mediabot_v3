# t/cases/990_mb708_portal_collector.t
use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Spark::Portal;

return sub {
    my ($assert) = @_;

    my $now = 1_000;
    my $portal = Mediabot::Spark::Portal->new(clock => sub { $now });

    my $begin = $portal->begin(channel => '#spark', generation => 17);
    $assert->is($begin->{action}, 'begin',
        'mb708-990: Portal collection starts only for an explicit event generation');
    $assert->is($portal->snapshot('#SPARK')->{phase}, 'collecting',
        'mb708-990: Portal channel keys are case-insensitive');

    my $command = $portal->collect(
        channel => '#spark', generation => 17, nick => 'Alice',
        bot_nick => 'Mediabot', message => '!help', command_char => '!',
    );
    $assert->is($command->{reason}, 'command',
        'mb708-990: command traffic never becomes a Portal contribution');

    my $first = $portal->collect(
        channel => '#spark', generation => 17, nick => 'Alice',
        bot_nick => 'Mediabot',
        message => "\x02une cape beaucoup trop sûre d'elle\x0f",
        command_char => '!',
    );
    $assert->is($first->{count}, 1,
        'mb708-990: first distinct human contribution is accepted');
    $assert->is($first->{ready}, 0,
        'mb708-990: one contribution cannot close a three-person Portal');

    my $duplicate = $portal->collect(
        channel => '#spark', generation => 17, nick => 'ALICE',
        bot_nick => 'Mediabot', message => 'une deuxième réponse',
        command_char => '!',
    );
    $assert->is($duplicate->{reason}, 'duplicate_nick',
        'mb708-990: one nick cannot fill several Portal slots');
    $assert->is($duplicate->{count}, 1,
        'mb708-990: a duplicate nick leaves the contribution count unchanged');

    my $second = $portal->collect(
        channel => '#spark', generation => 17, nick => 'Bob',
        bot_nick => 'Mediabot', message => 'un hibou syndiqué',
        command_char => '!',
    );
    $assert->is($second->{count}, 2,
        'mb708-990: second distinct nick opens the deadline fallback');

    my $third = $portal->collect(
        channel => '#spark', generation => 17, nick => 'Carol',
        bot_nick => 'Mediabot', message => 'un formulaire en feu',
        command_char => '!',
    );
    $assert->is($third->{reason}, 'target_reached',
        'mb708-990: third distinct contribution reaches the Portal target');
    $assert->is($third->{ready}, 1,
        'mb708-990: target completion is explicit and deterministic');

    my $items = $portal->contributions(
        channel => '#spark', generation => 17,
    );
    $assert->is(scalar(@$items), 3,
        'mb708-990: private contribution boundary contains exactly three items');
    $assert->unlike(join(' ', @$items), qr/Alice|Bob|Carol/,
        'mb708-990: contributor nicks never enter the AI contribution payload');
    $assert->unlike(join(' ', @$items), qr/[\x02\x0f]/,
        'mb708-990: IRC presentation controls are stripped before storage');

    my $closing = $portal->mark_closing(
        channel => '#spark', generation => 17,
    );
    $assert->is($closing->{action}, 'close',
        'mb708-990: a complete Portal enters one explicit closing phase');
    $assert->is($portal->snapshot('#spark')->{phase}, 'closing',
        'mb708-990: closing phase is observable through metadata only');

    my $late = $portal->collect(
        channel => '#spark', generation => 17, nick => 'Dave',
        bot_nick => 'Mediabot', message => 'trop tard', command_char => '!',
    );
    $assert->is($late->{reason}, 'closing',
        'mb708-990: contribution set freezes while synthesis is in flight');

    my $log = Mediabot::Spark::Portal::format_portal_log('#spark', $third);
    $assert->like($log, qr/^\[SPARK_PORTAL\].*action=collect.*count=3.*target=3/,
        'mb708-990: Portal diagnostics expose bounded lifecycle metadata');
    $assert->unlike($log, qr/cape|hibou|formulaire|Alice|Bob|Carol/i,
        'mb708-990: Portal logs contain neither contribution text nor nicks');

    $now += 30;
    $assert->is($portal->snapshot('#spark')->{closing_timed_out}, 1,
        'mb708-990: a stuck Portal synthesis receives a bounded timeout');
    $assert->is($portal->forget_channel('#spark'), 1,
        'mb708-990: channel cleanup destroys all ephemeral Portal material');
    $assert->is($portal->snapshot('#spark')->{active}, 0,
        'mb708-990: cleaned Portal state cannot resurrect old contributions');

    $portal->begin(channel => '#fallback', generation => 18);
    for my $row ([Eve => 'une théière'], [Frank => 'un dragon comptable']) {
        $portal->collect(
            channel => '#fallback', generation => 18,
            nick => $row->[0], bot_nick => 'Mediabot',
            message => $row->[1], command_char => '!',
        );
    }
    my $fallback = $portal->mark_closing(
        channel => '#fallback', generation => 18,
    );
    $assert->is($fallback->{action}, 'close',
        'mb708-990: exactly two distinct contributions may close at deadline');

    $portal->begin(channel => '#miss', generation => 19);
    $portal->collect(
        channel => '#miss', generation => 19, nick => 'Grace',
        bot_nick => 'Mediabot', message => 'seule', command_char => '!',
    );
    my $insufficient = $portal->mark_closing(
        channel => '#miss', generation => 19,
    );
    $assert->is($insufficient->{reason}, 'insufficient_contributions',
        'mb708-990: zero or one contribution cannot fabricate a Portal payoff');
};
