use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use Mediabot::Spark::Generator qw(
    build_spark_request
    parse_spark_generation
    spark_request_summary
);
use Mediabot::Spark::Mosaic qw(mosaic_opening_generation);
use Mediabot::Spark::Sender;

return sub {
    my ($assert) = @_;

    my $request = build_spark_request(
        kind => 'mosaic', language => 'fr', provider => 'auto',
        contributions => [ 'hibou', 'théière', 'paradoxe' ],
    );
    $assert->is($request->{purpose}, 'spark.mosaic',
        'mb710-1012: Mosaic close has one provider-neutral purpose');
    $assert->like($request->{system}, qr/Fuse every safe ingredient/i,
        'mb710-1012: closing contract uses the whole safe word set');
    $assert->like($request->{system}, qr/Never name, rank, score/i,
        'mb710-1012: closing contract forbids participant ranking');
    $assert->like($request->{system}, qr/omit an ingredient.*unsafe/i,
        'mb710-1012: unsafe word material may be omitted rather than echoed');
    $assert->like($request->{messages}[0]{content}, qr/hibou.*théière.*paradoxe/is,
        'mb710-1012: bounded words cross only the closing request boundary');

    my $too_few = eval {
        build_spark_request(
            kind => 'mosaic', contributions => [ 'solitude' ],
        );
        1;
    };
    $assert->ok(!$too_few,
        'mb710-1012: synthesis refuses fewer than two voices');

    my $parsed = parse_spark_generation(
        'mosaic',
        'LINE: Le hibou verse le paradoxe dans une théière administrative.',
    );
    $assert->is($parsed->{action}, 'ready',
        'mb710-1012: one-line payoff remains IRC-renderable');
    $assert->is(spark_request_summary($request)->{purpose}, 'spark.mosaic',
        'mb710-1012: request summary exposes metadata only');

    my $now = 20_000;
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
        current_generation => 72,
    };

    my $open = mosaic_opening_generation(language => 'fr', target => 3);
    my $opened = $sender->attempt_send(
        channel => '#spark', kind => 'mosaic', generation => 72,
        generated => $open, state_cb => sub { return { %$state } },
    );
    $assert->is($opened->{action}, 'sent',
        'mb710-1012: local opener uses the ordinary guarded sender path');

    $now += 5;
    my $closed = $sender->attempt_send(
        channel => '#spark', kind => 'mosaic', generation => 72,
        continuation => 1, generated => $parsed,
        state_cb => sub { return { %$state } },
    );
    $assert->is($closed->{action}, 'sent',
        'mb710-1012: same-event payoff receives one bounded continuation');
    $assert->is($closed->{continuation}, 1,
        'mb710-1012: continuation authority is explicit metadata');
    $assert->is(scalar(@sent), 2,
        'mb710-1012: opener and payoff are the only two deliveries');

    my $replay = $sender->attempt_send(
        channel => '#spark', kind => 'mosaic', generation => 72,
        continuation => 1, generated => $parsed,
        state_cb => sub { return { %$state } },
    );
    $assert->is($replay->{reason}, 'continuation_unavailable',
        'mb710-1012: payoff continuation cannot be replayed');

    my $log = Mediabot::Spark::Sender::format_sender_log('#spark', $closed);
    $assert->like($log, qr/kind=mosaic.*continuation=1/,
        'mb710-1012: sender records the family and continuation decision');
    $assert->unlike($log, qr/hibou|paradoxe|théière/i,
        'mb710-1012: sender diagnostics remain content-free');
};
