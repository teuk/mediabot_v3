use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use Mediabot::Spark::Event qw(
    spark_event_profile spark_event_is_momentum spark_event_is_selectable
);
use Mediabot::Spark::Generator qw(build_spark_request parse_spark_generation);
use Mediabot::Spark::Selector qw(select_spark_event select_spark_action);
use Mediabot::Spark::Sender;

return sub {
    my ($assert) = @_;

    $assert->ok(!spark_event_is_selectable('fork')
            && !spark_event_is_selectable('mosaic'),
        'mb739-1062: response-dependent legacy families are retired');
    $assert->ok(spark_event_is_selectable('aside')
            && spark_event_is_selectable('micro_scene'),
        'mb739-1062: autonomous revival families are selectable');

    my %seen;
    for my $cursor (0 .. 23) {
        my $pick = select_spark_event(
            recent_humans => 1, context_lines => 0, ai_available => 1,
            audience_regime => 'solo', cursor => $cursor,
        );
        $seen{$pick->{kind}}++ if ($pick->{action} // '') eq 'select';
    }
    $assert->ok($seen{aside} && $seen{micro_scene},
        'mb739-1062: a quiet solo room receives two autonomous registers');
    $assert->ok(!$seen{fork} && !$seen{mosaic} && !$seen{portal},
        'mb739-1062: solo revival never asks for a vote or collective response');

    my $first = select_spark_action(
        ai_available => 1, context_lines => 6, cursor => 0,
        audience_regime => 'social',
    );
    my $second = select_spark_action(
        ai_available => 1, context_lines => 6,
        cursor => $first->{next_cursor}, last_kind => $first->{kind},
        audience_regime => 'social',
    );
    $assert->is($first->{kind}, 'stage_cue',
        'mb739-1062: momentum repertoire keeps the physical stage cue');
    $assert->is($second->{kind}, 'afterglow',
        'mb739-1062: momentum repertoire rotates to a comic epilogue');
    $assert->ok(spark_event_is_momentum('afterglow'),
        'mb739-1062: Afterglow inherits the separate momentum authority');

    my $aside_request = build_spark_request(
        kind => 'aside', language => 'fr', context => [], provider => 'auto',
    );
    $assert->like($aside_request->{system}, qr/stand alone.*do not ask a question/is,
        'mb739-1062: Aside contract requires a self-contained non-question');
    my $scene = parse_spark_generation(
        'micro_scene', 'LINE: Une lampe cligne deux fois, puis nie toute implication.'
    );
    $assert->is($scene->{action}, 'ready',
        'mb739-1062: one-line autonomous micro-scene parses safely');
    $assert->is(parse_spark_generation('afterglow', 'NO_SPARK')->{reason},
        'model_declined',
        'mb739-1062: imprecise Afterglow can remain silent');

    my @wire;
    my $sender = Mediabot::Spark::Sender->new(
        clock => sub { 50_000 },
        send_cb => sub { push @wire, [ @_ ]; return 1 },
    );
    $sender->arm();
    my $generated = {
        action => 'ready', reason => 'generated', kind => 'afterglow',
        content => { line => 'Rapport final : le plan fonctionne surtout hors caméra.' },
    };
    my %state = (
        enabled => 1, action_enabled => 1, action_armed => 1,
        runtime_active => 1, irc_connected => 1, channel_joined => 1,
        flood_suppressed => 0, game_active => 0, wit_pending => 0,
        current_generation => 17,
    );
    my $sent = $sender->attempt_send(
        channel => '#spark', kind => 'afterglow', generation => 17,
        generated => $generated, state_cb => sub { return { %state } },
    );
    $assert->is($sent->{action}, 'sent',
        'mb739-1062: authorized Afterglow crosses the guarded sender');
    $assert->is($sent->{delivery}, 'message',
        'mb739-1062: Afterglow is an ordinary message, not a CTCP action');
    $assert->unlike($wire[0][1], qr/\x01ACTION/,
        'mb739-1062: Afterglow cannot manufacture an action frame');
};
