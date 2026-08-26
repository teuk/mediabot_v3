# t/cases/937_mb702_wit_flood_guard_foundation.t
# =============================================================================
# MB702-A1 — pure per-channel flood circuit breaker before provider invocation.
# =============================================================================

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::AI::ConversationFloodGuard qw(flood_defaults flood_summary);

return sub {
    my ($assert) = @_;

    my $defaults = flood_defaults();
    $assert->is($defaults->{window_seconds}, 10,
        'mb702-937: default burst window is 10 seconds');
    $assert->is($defaults->{threshold_lines}, 20,
        'mb702-937: default flood threshold is 20 public lines per window');
    $assert->is($defaults->{suppression_seconds}, 180,
        'mb702-937: default flood suppression lasts three minutes');
    $assert->is($defaults->{max_channels}, 256,
        'mb702-937: per-process flood state has a bounded channel count');

    my $now = 1_000;
    my $guard = Mediabot::AI::ConversationFloodGuard->new(
        clock => sub { $now },
    );

    for my $n (1 .. 19) {
        my $result = $guard->observe_public_line(channel => '#FloodTest');
        $assert->is($result->{action}, 'allow',
            "mb702-937: line $n remains below the default flood threshold");
        $assert->is($result->{reason}, 'below_threshold',
            "mb702-937: line $n exposes only bounded below-threshold metadata");
    }

    my $trip = $guard->observe_public_line(channel => '#floodtest');
    $assert->is($trip->{action}, 'suppress',
        'mb702-937: threshold line trips the per-channel circuit breaker');
    $assert->is($trip->{reason}, 'flood_suppression',
        'mb702-937: tripped circuit breaker has a stable machine-visible reason');
    $assert->is($trip->{retry_after_seconds}, 180,
        'mb702-937: initial suppression exposes the full retry interval');

    $now = 1_001;
    my $blocked = $guard->observe_public_line(channel => '#FLOODTEST');
    $assert->is($blocked->{action}, 'suppress',
        'mb702-937: case-folded channel remains suppressed');
    $assert->is($blocked->{retry_after_seconds}, 179,
        'mb702-937: suppression retry decreases without extending on traffic');

    $now = 1_179;
    my $still_blocked = $guard->observe_public_line(channel => '#floodtest');
    $assert->is($still_blocked->{retry_after_seconds}, 1,
        'mb702-937: traffic just before expiry does not extend suppression');

    $now = 1_180;
    my $recovered = $guard->observe_public_line(channel => '#floodtest');
    $assert->is($recovered->{action}, 'allow',
        'mb702-937: channel recovers automatically when suppression expires');

    my $other = $guard->observe_public_line(channel => '#other');
    $assert->is($other->{action}, 'allow',
        'mb702-937: flood state is strictly per-channel');

    my $query_now = 1_001;
    my $query_guard = Mediabot::AI::ConversationFloodGuard->new(
        clock               => sub { $query_now },
        threshold_lines     => 3,
        suppression_seconds => 30,
    );
    $query_guard->observe_public_line(channel => '#query');
    $query_guard->observe_public_line(channel => '#query');
    my $query_trip = $query_guard->observe_public_line(channel => '#query');
    $assert->is($query_trip->{action}, 'suppress',
        'mb702-937: query fixture enters suppression normally');

    $query_now = 1_011;
    my $query1 = $query_guard->current_decision(channel => '#QUERY');
    $assert->is($query1->{action}, 'suppress',
        'mb702-937: current_decision reports active suppression without a new public line');
    $assert->is($query1->{retry_after_seconds}, 20,
        'mb702-937: current_decision exposes remaining retry time');

    my $events_before_query = scalar @{ $query_guard->{channel_state}{'#query'}{events} || [] };
    my $until_before_query = $query_guard->{channel_state}{'#query'}{suppressed_until};
    my $query2 = $query_guard->current_decision(channel => '#query');
    $assert->is(scalar @{ $query_guard->{channel_state}{'#query'}{events} || [] }, $events_before_query,
        'mb702-937: current_decision does not add synthetic flood events');
    $assert->is($query_guard->{channel_state}{'#query'}{suppressed_until}, $until_before_query,
        'mb702-937: current_decision does not extend suppression');

    $query_now = 1_031;
    my $query_recovered = $query_guard->current_decision(channel => '#query');
    $assert->is($query_recovered->{action}, 'allow',
        'mb702-937: current_decision observes automatic expiry without mutating history');

    my $sparse_now = 2_000;
    my $sparse = Mediabot::AI::ConversationFloodGuard->new(
        clock           => sub { $sparse_now },
        window_seconds  => 10,
        threshold_lines => 3,
    );
    for my $t (2_000, 2_011, 2_022) {
        $sparse_now = $t;
        my $result = $sparse->observe_public_line(channel => '#quiet');
        $assert->is($result->{action}, 'allow',
            "mb702-937: sparse line at t=$t ages out of the burst window");
    }

    my $case_now = 3_000;
    my $case_guard = Mediabot::AI::ConversationFloodGuard->new(
        clock               => sub { $case_now },
        threshold_lines     => 3,
        suppression_seconds => 30,
    );
    $case_guard->observe_public_line(channel => '#Phat');
    $case_guard->observe_public_line(channel => '#PHAT');
    my $case_trip = $case_guard->observe_public_line(channel => '#phat');
    $assert->is($case_trip->{action}, 'suppress',
        'mb702-937: RFC-style case folding cannot split one channel flood bucket');

    my $bounded_now = 4_000;
    my $bounded = Mediabot::AI::ConversationFloodGuard->new(
        clock        => sub { ++$bounded_now },
        max_channels => 2,
    );
    $bounded->observe_public_line(channel => '#one');
    $bounded->observe_public_line(channel => '#two');
    $bounded->observe_public_line(channel => '#three');
    $assert->is(scalar(keys %{ $bounded->{channel_state} }), 2,
        'mb702-937: channel-state memory remains bounded');
    $assert->ok(!exists($bounded->{channel_state}{'#one'}),
        'mb702-937: oldest channel state is evicted first when the cap is reached');

    my $bad = eval {
        $guard->observe_public_line(channel => 'Alice');
        1;
    };
    $assert->ok(!$bad && $@ =~ /public IRC channel/,
        'mb702-937: private/invalid targets are rejected at the flood boundary');

    my $summary = flood_summary({
        action              => 'suppress',
        reason              => 'flood_suppression',
        retry_after_seconds => 42,
        message             => 'secret message payload',
        nick                => 'Alice',
        api_key             => 'secret-key',
    });
    $assert->is($summary->{action}, 'suppress',
        'mb702-937: sanitized summary preserves suppression action');
    $assert->is($summary->{reason}, 'flood_suppression',
        'mb702-937: sanitized summary preserves suppression reason');
    $assert->is($summary->{retry_after_seconds}, 42,
        'mb702-937: sanitized summary preserves bounded retry metadata');
    $assert->ok(!exists($summary->{message}) && !exists($summary->{nick}) && !exists($summary->{api_key}),
        'mb702-937: summary cannot expose message, nick or credentials');

    my $rollback_clock = 5_000;
    my $rollback = Mediabot::AI::ConversationFloodGuard->new(
        clock               => sub { $rollback_clock },
        threshold_lines     => 3,
        suppression_seconds => 30,
    );
    $rollback->observe_public_line(channel => '#clock');
    $rollback_clock = 4_999;
    my $rollback_result = $rollback->observe_public_line(channel => '#clock');
    $assert->is($rollback_result->{action}, 'suppress',
        'mb702-937: backwards injected clock fails closed instead of clearing protection');
    $assert->is($rollback_result->{reason}, 'flood_suppression',
        'mb702-937: backwards-clock fail-closed path uses normal suppression metadata');

    my $module = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../Mediabot/AI/ConversationFloodGuard.pm"
            or die "open ConversationFloodGuard.pm: $!";
        local $/;
        <$fh>;
    };
    $assert->unlike($module, qr/\b(?:DBI|AI::Client|ConversationExecutor|Provider::Anthropic|Provider::OpenAI)\b/,
        'mb702-937: flood guard owns no database or provider dependency');
    $assert->unlike($module, qr/\b(?:botPrivmsg|botNotice|send_message|do_PRIVMSG|Net::Async::IRC)\b/,
        'mb702-937: flood guard owns no IRC emission primitive');

    my $dryrun = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../Mediabot/AI/ConversationDryRun.pm"
            or die "open ConversationDryRun.pm: $!";
        local $/;
        <$fh>;
    };
    $assert->like($dryrun, qr/use Mediabot::AI::ConversationFloodGuard \(\);/,
        'mb702-937: A2 may wire the pure guard while the guard itself remains dependency-free');
};
