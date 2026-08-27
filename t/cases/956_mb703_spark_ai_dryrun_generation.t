# t/cases/956_mb703_spark_ai_dryrun_generation.t
# =============================================================================
# MB703-E — Async Spark AI dry-run generation is revocable and one-per-channel.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Spark::DryRun;

{
    package MB703E::Generator;
    sub new { bless { calls => [], done => [] }, shift }
    sub submit {
        my ($self, %args) = @_;
        push @{ $self->{calls} }, { %args };
        push @{ $self->{done} }, $args{on_done};
        return 1;
    }
    sub complete {
        my ($self, $idx, $result) = @_;
        $self->{done}[$idx]->($result);
    }
    sub calls { $_[0]{calls} }
}

return sub {
    my ($assert) = @_;

    my $gen = MB703E::Generator->new;
    my $dry = Mediabot::Spark::DryRun->new(generator => $gen);
    my @result;

    my $g1 = $dry->submit_candidate(
        channel => '#spark', kind => 'callback', language => 'fr',
        context => [ 'Alice: ça tient encore', 'Bob: pour le moment' ],
        on_result => sub { push @result, shift },
    );
    $assert->is($g1, 1,
        'mb703-956: first async Spark dry-run receives a generation token');
    $assert->ok($dry->channel_inflight('#SPARK'),
        'mb703-956: channel is marked inflight case-insensitively');
    $assert->ok($dry->generation_is_current('#spark', $g1),
        'mb703-956: captured dry-run generation is current while request is inflight');

    my $duplicate = $dry->submit_candidate(
        channel => '#spark', kind => 'fork', language => 'fr',
        on_result => sub { push @result, shift },
    );
    $assert->is($duplicate, 0,
        'mb703-956: duplicate provider work for one channel fails closed');
    $assert->is(scalar(@{ $gen->calls }), 1,
        'mb703-956: duplicate dry-run did not reach the generator');

    $assert->is($dry->invalidate_channel('#spark'), 1,
        'mb703-956: human/runtime change can invalidate pending generation');
    $assert->ok(!$dry->generation_is_current('#spark', $g1),
        'mb703-956: invalidated generation is immediately stale');

    $gen->complete(0, {
        action => 'ready', reason => 'generated', kind => 'callback',
        provider => 'openai', model => 'gpt-test',
        provider_fallback => 0, model_fallback => 0,
        content => { line => 'Cette réponse arrive après la bataille.' },
    });
    $assert->is($result[0]{action}, 'revoked',
        'mb703-956: late provider completion is revoked');
    $assert->is($result[0]{reason}, 'stale_generation',
        'mb703-956: late completion exposes an explicit stale-generation reason');

    my $g2 = $dry->submit_candidate(
        channel => '#spark', kind => 'fork', language => 'fr',
        on_result => sub { push @result, shift },
    );
    $assert->is($g2, 2,
        'mb703-956: next request gets a distinct monotonically increasing token');

    $gen->complete(1, {
        action => 'ready', reason => 'generated', kind => 'fork',
        provider => 'anthropic', model => 'claude-test',
        provider_fallback => 0, model_fallback => 0,
        content => {
            question => 'On sauve quoi ?',
            a => 'La dignité',
            b => 'Les logs',
        },
    });
    $assert->is($result[1]{action}, 'ready',
        'mb703-956: current provider completion survives the generation gate');
    $assert->is($result[1]{generation}, 2,
        'mb703-956: accepted dry-run summary retains generation metadata');
    $assert->ok(!$dry->channel_inflight('#spark'),
        'mb703-956: completed request clears inflight state');

    my $log = Mediabot::Spark::DryRun::format_ai_dryrun_log('#spark', $result[1]);
    $assert->like($log, qr/^\[SPARK_AI_DRYRUN\].*action=ready.*kind=fork/,
        'mb703-956: successful generation has a grep-friendly metadata log');
    $assert->like($log, qr/provider=anthropic.*model=claude-test/,
        'mb703-956: provider/model diagnostics survive without content');
    $assert->unlike($log, qr/On sauve|dignit|logs/i,
        'mb703-956: AI dry-run log never exposes generated content');
};
