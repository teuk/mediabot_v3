use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use Mediabot::Spark::Audience qw(summarize_audience);
use Mediabot::Spark::Observer;

return sub {
    my ($assert) = @_;

    my $balanced = summarize_audience(
        human_weights => { a => 1_000, b => 1_000, c => 1_000 },
        human_lines => 9, bot_pressure_lines => 1,
        window_seconds => 600, now => 1_000,
        last_human_at => 990, last_bot_pressure_at => 980,
    );
    $assert->is($balanced->{effective_humans_milli}, 3_000,
        'mb710-1003: balanced participation yields three effective humans');
    $assert->is($balanced->{dominant_share_pct}, 33,
        'mb710-1003: balanced participation has no dominant speaker');
    $assert->is($balanced->{human_line_rate_milli}, 900,
        'mb710-1003: line rate is normalized per minute');
    $assert->is($balanced->{bot_pressure_share_pct}, 10,
        'mb710-1003: bot pressure is measured against visible traffic');

    my $dominated = summarize_audience(
        human_weights => { a => 8_000, b => 1_000, c => 1_000 },
        human_lines => 10, window_seconds => 600, now => 1_000,
    );
    $assert->ok($dominated->{effective_humans_milli} < 1_600,
        'mb710-1003: one dominant speaker does not masquerade as a group of three');
    $assert->is($dominated->{dominant_share_pct}, 80,
        'mb710-1003: dominant share remains explicit metadata');

    my $now = 20_000;
    my $observer = Mediabot::Spark::Observer->new(
        clock => sub { $now }, max_lines => 3,
    );
    for my $row (
        [Alice => 'une'], [Bob => 'deux'], [Carol => 'trois'],
        [Alice => 'quatre'], [Bob => 'cinq'], [Carol => 'six'],
    ) {
        $observer->observe_public_line(
            channel => '#room', nick => $row->[0], bot_nick => 'Mediabot',
            message => $row->[1], command_char => '!',
        );
        $now++;
    }
    $observer->observe_public_line(
        channel => '#room', nick => 'Relay', bot_nick => 'Mediabot',
        message => 'automated item', command_char => '!', from_bot => 1,
    );
    $now++;
    $observer->observe_public_line(
        channel => '#room', nick => 'Alice', bot_nick => 'Mediabot',
        message => 'm status', command_char => '!', initial_trigger_enabled => 1,
    );

    my $summary = $observer->activity_summary('#room', window_seconds => 600);
    $assert->is(scalar(@{ $observer->context_lines('#room') }), 3,
        'mb710-1003: provider context keeps its independent small bound');
    $assert->is($summary->{line_count}, 6,
        'mb710-1003: activity metadata retains all bounded human lines');
    $assert->is($summary->{distinct_humans}, 3,
        'mb710-1003: automation and commands do not become humans');
    $assert->is($summary->{bot_pressure_lines}, 2,
        'mb710-1003: automation and commands become bot pressure');
    $assert->unlike(join(',', sort keys %$summary), qr/(?:nick|message|text)/i,
        'mb710-1003: audience summary schema exposes no identity or text');
};
