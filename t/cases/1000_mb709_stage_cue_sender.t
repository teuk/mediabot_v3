use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use Mediabot::Spark::Sender;

return sub {
    my ($assert) = @_;
    my $now = 4_000;
    my @sent;
    my $sender = Mediabot::Spark::Sender->new(
        clock => sub { $now },
        send_cb => sub { push @sent, [ @_ ]; return 1; },
    );
    $sender->arm();

    my $generated = {
        action => 'ready', reason => 'generated', kind => 'stage_cue',
        content => { line => 'déplie un minuscule tapis rouge pour le café.' },
    };
    my %state = (
        enabled => 1, action_enabled => 1, action_armed => 0,
        runtime_active => 1, irc_connected => 1, channel_joined => 1,
        flood_suppressed => 0, game_active => 0, wit_pending => 0,
        current_generation => 9,
    );

    my $off = $sender->attempt_send(
        channel => '#spark', kind => 'stage_cue', generation => 9,
        generated => $generated, state_cb => sub { return { %state } },
    );
    $assert->is($off->{reason}, 'action_kill_switch',
        'mb709-1000: dedicated action arm fails closed at sender boundary');
    $assert->is(scalar(@sent), 0,
        'mb709-1000: disarmed action never reaches IRC transport');

    $state{action_armed} = 1;
    my $ok = $sender->attempt_send(
        channel => '#spark', kind => 'stage_cue', generation => 9,
        generated => $generated, state_cb => sub { return { %state } },
    );
    $assert->is($ok->{action}, 'sent',
        'mb709-1000: fully authorized Stage Cue is delivered');
    $assert->is($ok->{delivery}, 'action',
        'mb709-1000: result metadata distinguishes action delivery');
    $assert->is(
        $sent[0][1],
        "\x01ACTION \x{2728} déplie un minuscule tapis rouge pour le café.\x01",
        'mb709-1000: sender constructs exactly one bounded CTCP ACTION frame',
    );

    my $log = Mediabot::Spark::Sender::format_sender_log('#spark', $ok);
    $assert->like($log, qr/kind=stage_cue delivery=action/,
        'mb709-1000: metadata log identifies family and delivery style');
    $assert->unlike($log, qr/tapis|café/,
        'mb709-1000: action text never enters sender logs');

    my $unsafe = Mediabot::Spark::Sender::render_generation({
        action => 'ready', kind => 'stage_cue',
        content => { line => "waves\x01ACTION injected\x01" },
    });
    $assert->ok(!defined($unsafe),
        'mb709-1000: model-supplied CTCP controls are rejected');

    my $mismatch = Mediabot::Spark::Sender->new(
        clock => sub { $now + 200 }, send_cb => sub { return 1 },
    );
    $mismatch->arm();
    my $wrong = $mismatch->attempt_send(
        channel => '#spark', kind => 'reaction', generation => 9,
        generated => $generated,
        state_cb => sub { return { %state } },
    );
    $assert->is($wrong->{reason}, 'kind_mismatch',
        'mb709-1000: candidate kind cannot be swapped before delivery');
};
