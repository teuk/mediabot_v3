# MB720-C — independent Hailo policy, cooldowns and bounded queue.

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Hailo::Policy;
use Mediabot::Hailo::ReplyQueue;

return sub {
    my ($assert) = @_;
    my $now = 100;
    my $roll = 0;
    my $policy = Mediabot::Hailo::Policy->new(
        now_cb         => sub { $now },
        rng_cb         => sub { $roll },
        learn_interval => 5,
        reply_interval => 5,
        flood_max      => 2,
        flood_window   => 30,
        min_words      => 3,
        max_words      => 6,
        key_reply_rate => 95,
    );

    my %base = (
        channel         => '#test',
        speaker         => 'alice',
        text            => 'bonjour tout le monde',
        mode            => 'mention',
        master_enabled  => 1,
        learn_enabled   => 1,
        respond_enabled => 1,
        chatter_enabled => 0,
    );

    my $first = $policy->decide(%base);
    $assert->ok($first->{learn} && $first->{reply},
        'direct mention may independently learn and reply');
    $policy->record_learn(channel => '#test', speaker => 'alice');
    $policy->record_reply(channel => '#test', speaker => 'alice');

    $now = 102;
    my $cooldown = $policy->decide(%base);
    $assert->is($cooldown->{learn_reason}, 'learn_cooldown',
        'per-user learn cooldown blocks pasted consecutive lines');
    $assert->is($cooldown->{reply_reason}, 'reply_cooldown',
        'per-user reply cooldown blocks repeated triggers');

    $now = 106;
    my $after = $policy->decide(%base);
    $assert->ok($after->{learn} && $after->{reply},
        'learn and reply become eligible after their cooldowns');
    $policy->record_reply(channel => '#test', speaker => 'alice');

    my $flood = $policy->decide(%base, speaker => 'bob');
    $assert->is($flood->{reply_reason}, 'channel_flood',
        'per-channel sliding window caps aggregate Hailo replies');

    my $learn_only = $policy->decide(
        %base,
        speaker         => 'carol',
        mode            => 'ambient',
        respond_enabled => 0,
    );
    $assert->ok($learn_only->{learn},
        'ambient line can train when learning is enabled');
    $assert->ok(!$learn_only->{reply},
        'ambient line does not speak without a reply lane');

    my $respond_only = $policy->decide(
        %base,
        speaker       => 'dave',
        learn_enabled => 0,
    );
    $assert->ok(!$respond_only->{learn},
        'HailoLearn independently disables learning');
    $assert->ok(!$respond_only->{reply},
        'channel flood remains authoritative for ordinary replies');

    my $command = $policy->decide(
        %base,
        speaker   => 'erin',
        is_command => 1,
    );
    $assert->is($command->{learn_reason}, 'command',
        'ordinary IRC commands are not learned');
    $assert->is($command->{reply_reason}, 'command',
        'ordinary IRC commands are not answered by Hailo');

    my $forced = $policy->decide(
        %base,
        speaker          => 'master',
        text             => '& phrase forcée pour test',
        force_authorized => 1,
    );
    $assert->is($forced->{force}, 'learn_reply',
        'authorized ampersand keeps MegaHAL force-learn-and-reply semantics');
    $assert->is($forced->{text}, 'phrase forcée pour test',
        'authorized force prefix is removed before Hailo sees the sentence');
    $assert->ok($forced->{learn} && $forced->{reply},
        'authorized force control overrides ordinary cooldown and flood gates');

    my $unauthorized = $policy->decide(
        %base,
        speaker          => 'guest',
        text             => '& phrase ordinaire pour test',
        force_authorized => 0,
    );
    $assert->is($unauthorized->{force}, 'normal',
        'force prefixes are inert without an authenticated privilege bridge');

    my $master_off = $policy->decide(%base, master_enabled => 0, speaker => 'z');
    $assert->is($master_off->{reason}, 'master_disabled',
        'Hailo master switch is authoritative over all sub-switches');

    my $rate_policy = Mediabot::Hailo::Policy->new(
        now_cb => sub { 1 }, rng_cb => sub { 99 }, key_reply_rate => 95,
        min_words => 1,
    );
    my $rate = $rate_policy->decide(%base, text => 'hello there friend');
    $assert->is($rate->{reply_reason}, 'key_reply_rate',
        'direct trigger probability is independently configurable');

    my $queue_now = 10;
    my @delivered;
    my $queue = Mediabot::Hailo::ReplyQueue->new(
        now_cb          => sub { $queue_now },
        max_total       => 3,
        max_per_channel => 2,
        ttl_seconds     => 5,
    );
    my $q1 = $queue->enqueue(
        channel => '#a', payload => 'one',
        on_ready => sub { push @delivered, $_[0] },
    );
    my $q2 = $queue->enqueue(
        channel => '#a', payload => 'two',
        on_ready => sub { push @delivered, $_[0] },
    );
    my $q3 = $queue->enqueue(
        channel => '#a', payload => 'three',
        on_ready => sub { push @delivered, $_[0] },
    );
    $assert->ok($q1->{accepted} && $q2->{accepted},
        'queue accepts work inside the per-channel bound');
    $assert->is($q3->{reason}, 'channel_queue_full',
        'queue rejects excess work instead of growing without limit');
    $assert->ok($queue->dispatch_next,
        'oldest accepted reply dispatches through its callback');
    $assert->is($delivered[0], 'one',
        'reply queue preserves FIFO order');

    my $expired_payload;
    my $q4 = $queue->enqueue(
        channel => '#b', payload => 'parallel',
        on_ready => sub { push @delivered, $_[0] },
    );
    $assert->ok($q4->{accepted}, 'a second channel may enter the global queue');
    my $parallel = $queue->take_next(sub { $_[0]{channel_key} eq '#b' });
    $assert->is($parallel->{payload}, 'parallel',
        'ready predicate skips a busy channel without breaking its FIFO entry');

    # Replace the remaining #a entry's expiry callback through a fresh bounded
    # queue so expiration is observable without exposing its payload publicly.
    my $expiring = Mediabot::Hailo::ReplyQueue->new(
        now_cb => sub { $queue_now }, ttl_seconds => 5,
    );
    $expiring->enqueue(
        channel => '#a', payload => 'private-payload', on_ready => sub { 1 },
        on_expire => sub { $expired_payload = $_[0]{payload} },
    );

    $queue_now = 20;
    $assert->is($queue->stats->{queued}, 0,
        'expired provider-bound reply is removed without emission');
    $assert->is($queue->stats->{dropped_expired}, 1,
        'queue exposes only aggregate expiry telemetry');
    $assert->is($expiring->stats->{dropped_expired}, 1,
        'expiry callback and aggregate counter share one prune boundary');
    $assert->is($expired_payload, 'private-payload',
        'runtime receives the expired private job for metadata-only completion');
    $assert->is($queue->ttl_seconds, 5,
        'runtime can enforce the same queue TTL at the late emission gate');
    $assert->ok($queue->typing_delay_seconds('une réponse assez courte') > 0,
        'typing delay derives from bounded line length like MegaHAL interface');

    my $reentrant_stats;
    my $reentrant = Mediabot::Hailo::ReplyQueue->new(
        now_cb => sub { $queue_now }, ttl_seconds => 5,
    );
    $reentrant->enqueue(
        channel   => '#metrics',
        payload   => 'private-payload',
        on_ready  => sub { 1 },
        on_expire => sub { $reentrant_stats = $reentrant->stats },
    );
    $queue_now += 6;
    my $after_reentrant = $reentrant->stats;
    $assert->is($reentrant_stats->{queued}, 0,
        'expiry callbacks may read queue metrics without recursive pruning');
    $assert->is($after_reentrant->{dropped_expired}, 1,
        'reentrant metric read does not double-count the expired entry');
};
