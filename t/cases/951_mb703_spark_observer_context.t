# t/cases/951_mb703_spark_observer_context.t
# =============================================================================
# MB703-D — Bounded ephemeral public-channel context observer.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Spark::Observer;

return sub {
    my ($assert) = @_;

    my $now = 10_000;
    my $obs = Mediabot::Spark::Observer->new(
        clock          => sub { $now },
        max_lines      => 3,
        max_line_chars => 40,
        max_age_seconds => 300,
    );

    my $r = $obs->observe_public_line(
        channel => '#spark', nick => 'Alice', bot_nick => 'Mediabot',
        message => "\x02Le serveur\x0f tient encore", command_char => '!',
    );
    $assert->is($r->{action}, 'observe',
        'mb703-951: a normal human line enters the ephemeral context buffer');

    $now += 1;
    $r = $obs->observe_public_line(
        channel => '#spark', nick => 'Bob', bot_nick => 'Mediabot',
        message => '!status', command_char => '!',
    );
    $assert->is($r->{reason}, 'command',
        'mb703-951: bot commands are not copied into provider context');

    $now += 1;
    $r = $obs->observe_public_line(
        channel => '#spark', nick => 'Carol', bot_nick => 'Mediabot',
        message => 'Mediabot: raconte quelque chose', command_char => '!',
    );
    $assert->is($r->{reason}, 'bot_trigger',
        'mb703-951: direct bot triggers are excluded from Spark context');

    for my $pair (
        [Dave => 'deuxieme ligne'],
        [Eve  => 'troisieme ligne'],
        [Fred => 'quatrieme ligne'],
    ) {
        $now += 1;
        $obs->observe_public_line(
            channel => '#spark', nick => $pair->[0], bot_nick => 'Mediabot',
            message => $pair->[1], command_char => '!',
        );
    }

    my $lines = $obs->context_lines('#spark');
    $assert->is(scalar(@$lines), 3,
        'mb703-951: context window is hard-bounded by line count');
    $assert->unlike(join(' ', @$lines), qr/Le serveur/,
        'mb703-951: oldest context is evicted when the bound is reached');
    $assert->like($lines->[2], qr/^Fred: quatrieme ligne$/,
        'mb703-951: context keeps only sanitized nick/text pairs');
    $assert->unlike(join(' ', @$lines), qr/[\x02\x03\x0f]/,
        'mb703-951: IRC presentation controls never survive in context');

    my $summary = $obs->context_summary('#spark');
    $assert->is($summary->{line_count}, 3,
        'mb703-951: summary exposes metadata only');
    $assert->ok(!exists($summary->{lines}) && !exists($summary->{text}),
        'mb703-951: summary never exposes conversation content');

    $now += 301;
    $lines = $obs->context_lines('#spark');
    $assert->is(scalar(@$lines), 0,
        'mb703-951: stale conversation text expires from memory');

    $obs->forget_channel('#spark');
    $assert->is(scalar(@{ $obs->channels() }), 0,
        'mb703-951: channel context can be explicitly forgotten');
};
