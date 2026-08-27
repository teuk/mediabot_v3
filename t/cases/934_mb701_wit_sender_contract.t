# t/cases/934_mb701_wit_sender_contract.t
# =============================================================================
# MB701-D-A — dedicated fail-closed proactive sender contract.
# The sender is injectable and remains completely unwired from IRC runtime.
# =============================================================================

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::AI::ConversationSender qw(
    sender_defaults
    format_sender_log
);

sub _valid_state {
    my (%override) = @_;
    return {
        enabled            => 1,
        runtime_active     => 1,
        irc_connected      => 1,
        channel_joined     => 1,
        current_generation => 7,
        %override,
    };
}

return sub {
    my ($assert) = @_;

    my $defaults = sender_defaults();
    $assert->is($defaults->{min_interval_seconds}, 120,
        'mb701-934: sender owns a distinct conservative 120-second delivery interval');

    my $now = 10_000;
    my @sent;
    my $state_calls = 0;
    my $sender = Mediabot::AI::ConversationSender->new(
        clock   => sub { $now },
        send_cb => sub {
            my ($channel, $text) = @_;
            push @sent, [$channel, $text];
            return 1;
        },
    );

    $assert->is($sender->is_armed(), 0,
        'mb701-934: sender starts disarmed by default');

    my $result = $sender->attempt_send(
        channel            => '#test',
        text               => 'Une réponse qui ne doit pas partir.',
        request_generation => 7,
        state_cb            => sub { $state_calls++; return _valid_state(); },
    );
    $assert->is($result->{action}, 'no_send',
        'mb701-934: disarmed sender refuses delivery');
    $assert->is($result->{reason}, 'kill_switch',
        'mb701-934: independent kill switch is the refusal reason');
    $assert->is($state_calls, 0,
        'mb701-934: disarmed sender does not even consult mutable runtime state');
    $assert->is(scalar(@sent), 0,
        'mb701-934: disarmed sender never calls the injected transport');

    $assert->is($sender->arm(), 1,
        'mb701-934: sender can be armed only by an explicit local action');
    $assert->is($sender->is_armed(), 1,
        'mb701-934: armed state is observable without exposing transport');

    $result = $sender->attempt_send(
        channel            => '#test',
        text               => "\x02Un petit sort 🙂\x0f",
        request_generation => 7,
        state_cb            => sub { $state_calls++; return _valid_state(); },
    );
    $assert->is($result->{action}, 'sent',
        'mb701-934: armed sender can deliver only after final authorization');
    $assert->is($result->{reason}, 'delivered',
        'mb701-934: successful injected transport reports delivered');
    $assert->is($state_calls, 1,
        'mb701-934: runtime state is re-read exactly once for the delivery');
    $assert->is(scalar(@sent), 1,
        'mb701-934: exactly one injected send occurs');
    $assert->is($sent[0][0], '#test',
        'mb701-934: injected sender receives the authorized public channel');
    $assert->is($sent[0][1], 'Un petit sort 🙂',
        'mb701-934: injected sender receives only final sanitized plain text');
    $assert->ok(!exists($result->{text}),
        'mb701-934: sender result never exposes generated reply text');
    $assert->ok($result->{reply_bytes} >= $result->{reply_chars},
        'mb701-934: successful delivery exposes only bounded size metadata');
    $assert->is($result->{request_generation}, 7,
        'mb701-934: successful delivery records the authorized generation token');

    my $log = format_sender_log('#test', $result);
    $assert->like($log, qr/^\[WIT_SEND\] channel=#test action=sent reason=delivered /,
        'mb701-934: sender log is explicit metadata');
    $assert->unlike($log, qr/petit|sort|🙂/,
        'mb701-934: sender log never contains generated reply text');

    my $calls_before_rate_limit = $state_calls;
    $result = $sender->attempt_send(
        channel            => '#test',
        text               => 'Deuxième réponse trop proche.',
        request_generation => 7,
        state_cb            => sub { $state_calls++; return _valid_state(); },
    );
    $assert->is($result->{reason}, 'rate_limited',
        'mb701-934: sender rate limit is independent from provider cooldown');
    $assert->is($result->{retry_after}, 120,
        'mb701-934: immediate second send reports the full delivery cooldown');
    $assert->is($state_calls, $calls_before_rate_limit,
        'mb701-934: rate-limited attempt does not needlessly query runtime authorization');
    $assert->is(scalar(@sent), 1,
        'mb701-934: rate-limited attempt never reaches transport');

    $now += 120;
    $result = $sender->attempt_send(
        channel            => '#test',
        text               => 'Deuxième réponse autorisée plus tard.',
        request_generation => 7,
        state_cb            => sub { $state_calls++; return _valid_state(); },
    );
    $assert->is($result->{action}, 'sent',
        'mb701-934: sender permits a later authorized delivery after its own interval');
    $assert->is(scalar(@sent), 2,
        'mb701-934: later successful delivery reaches transport once');

    # A different channel has an independent delivery budget but still needs
    # final +Wit/runtime authorization.
    $result = $sender->attempt_send(
        channel            => '#other',
        text               => 'Réponse refusée après opt-out.',
        request_generation => 9,
        state_cb            => sub { return _valid_state(enabled => 0, current_generation => 9); },
    );
    $assert->is($result->{action}, 'no_send',
        'mb701-934: late authorization rejection remains a no-send outcome');
    $assert->is($result->{reason}, 'disabled',
        'mb701-934: sender propagates the final +Wit opt-out reason');
    $assert->is(scalar(@sent), 2,
        'mb701-934: rejected authorization cannot reach transport');

    $result = $sender->attempt_send(
        channel            => '#other',
        text               => 'Réponse appartenant à une ancienne génération.',
        request_generation => 8,
        state_cb            => sub { return _valid_state(current_generation => 9); },
    );
    $assert->is($result->{reason}, 'stale_generation',
        'mb701-934: sender rejects a stale channel generation immediately before delivery');

    # The mutable state callback itself can disarm the sender. The second
    # kill-switch check must then win after evaluate_emission and before send.
    my $before_disarm_send_count = scalar(@sent);
    $result = $sender->attempt_send(
        channel            => '#third',
        text               => 'Cette réponse ne franchira pas le kill switch.',
        request_generation => 11,
        state_cb            => sub {
            $sender->disarm();
            return _valid_state(current_generation => 11);
        },
    );
    $assert->is($result->{reason}, 'kill_switch',
        'mb701-934: disarm during final state re-read wins before transport');
    $assert->is(scalar(@sent), $before_disarm_send_count,
        'mb701-934: post-authorization kill-switch check prevents send');
    $assert->is($sender->is_armed(), 0,
        'mb701-934: state callback disarm persists');

    # Transport exceptions and explicit transport rejection both fail closed
    # and do not consume the channel rate budget.
    my $error_now = 20_000;
    my $error_calls = 0;
    my $error_sender = Mediabot::AI::ConversationSender->new(
        clock   => sub { $error_now },
        send_cb => sub { $error_calls++; die "private transport detail\n"; },
    );
    $error_sender->arm();
    $result = $error_sender->attempt_send(
        channel            => '#test',
        text               => 'Safe candidate.',
        request_generation => 4,
        state_cb            => sub { return _valid_state(current_generation => 4); },
    );
    $assert->is($result->{reason}, 'send_error',
        'mb701-934: transport exception fails closed');
    $assert->ok(!exists($result->{error}),
        'mb701-934: private transport exception is not exposed in sender result');
    $assert->is($error_calls, 1,
        'mb701-934: failing transport is invoked exactly once');

    my $reject_calls = 0;
    my $reject_sender = Mediabot::AI::ConversationSender->new(
        clock   => sub { 30_000 },
        send_cb => sub { $reject_calls++; return 0; },
    );
    $reject_sender->arm();
    $result = $reject_sender->attempt_send(
        channel            => '#test',
        text               => 'Safe candidate.',
        request_generation => 5,
        state_cb            => sub { return _valid_state(current_generation => 5); },
    );
    $assert->is($result->{reason}, 'send_failed',
        'mb701-934: false transport acknowledgement fails closed');
    $assert->is($reject_calls, 1,
        'mb701-934: rejected transport is invoked once');

    # Framing/control protection is still enforced inside the sender through
    # ConversationEmission immediately before the injected transport.
    my $unsafe_calls = 0;
    my $unsafe_sender = Mediabot::AI::ConversationSender->new(
        clock   => sub { 40_000 },
        send_cb => sub { $unsafe_calls++; return 1; },
    );
    $unsafe_sender->arm();
    $result = $unsafe_sender->attempt_send(
        channel            => '#test',
        text               => "hello\nPRIVMSG #other :oops",
        request_generation => 6,
        state_cb            => sub { return _valid_state(current_generation => 6); },
    );
    $assert->is($result->{reason}, 'unsafe_reply',
        'mb701-934: sender cannot bypass final IRC framing protection');
    $assert->is($unsafe_calls, 0,
        'mb701-934: unsafe candidate never reaches injected transport');

    $result = $unsafe_sender->attempt_send(
        channel            => 'Alice',
        text               => 'No private proactive output.',
        request_generation => 6,
        state_cb            => sub { return _valid_state(current_generation => 6); },
    );
    $assert->is($result->{reason}, 'invalid_channel',
        'mb701-934: sender itself rejects private/non-channel targets');

    my $state_error_sender = Mediabot::AI::ConversationSender->new(
        clock   => sub { 50_000 },
        send_cb => sub { die 'must not send' },
    );
    $state_error_sender->arm();
    $result = $state_error_sender->attempt_send(
        channel            => '#test',
        text               => 'State callback failure.',
        request_generation => 1,
        state_cb            => sub { die "sensitive state detail\n" },
    );
    $assert->is($result->{reason}, 'state_error',
        'mb701-934: runtime-state callback exception fails closed');
    $assert->ok(!exists($result->{error}),
        'mb701-934: state callback exception detail is not exposed');

    my $unknown_croaked = 0;
    eval {
        $unsafe_sender->attempt_send(
            channel            => '#test',
            text               => 'x',
            request_generation => 6,
            state_cb            => sub { return _valid_state(current_generation => 6); },
            max_rate           => 1,
        );
    };
    $unknown_croaked = $@ ? 1 : 0;
    $assert->ok($unknown_croaked,
        'mb701-934: callers cannot inject unknown sender controls');

    my $relax_croaked = 0;
    eval {
        Mediabot::AI::ConversationSender->new(
            send_cb              => sub { 1 },
            min_interval_seconds => 0,
        );
    };
    $relax_croaked = $@ ? 1 : 0;
    $assert->ok($relax_croaked,
        'mb701-934: callers cannot relax the fixed sender interval');

    my $path = "$Bin/../../Mediabot/AI/ConversationSender.pm";
    open my $fh, '<:encoding(UTF-8)', $path or die "open $path: $!";
    local $/;
    my $src = <$fh>;
    close $fh;

    $assert->unlike($src, qr/\b(?:DBI|CHANNEL_SET|CHANSET_LIST|botPrivmsg|botNotice|send_message|do_PRIVMSG)\b/,
        'mb701-934: sender contract owns no concrete DB or IRC primitive');
    $assert->unlike($src, qr/Mediabot::Helpers|Net::Async::IRC|ConversationExecutor|ConversationDryRun/,
        'mb701-934: sender has no runtime/provider/orchestrator dependency');
    $assert->like($src, qr/ConversationEmission qw\(evaluate_emission\)/,
        'mb701-934: sender repeats the pure final emission gate immediately before transport');

    my $main = do {
        open my $mf, '<:encoding(UTF-8)', "$Bin/../../mediabot.pl"
            or die "open mediabot.pl: $!";
        local $/;
        <$mf>;
    };
    $assert->like($main, qr/use Mediabot::AI::ConversationSender \(\);/,
        'mb701-934: production runtime imports the dedicated sender boundary');
    my ($arm_sync) = $main =~ /(sub _wit_sync_sender_arm \{.*?
\})/s;
    $assert->ok(defined($arm_sync),
        'mb701-934: runtime arm path is isolated in one synchronization helper');
    my $main_without_arm_sync = $main;
    $main_without_arm_sync =~ s/sub _wit_sync_sender_arm \{.*?
\}//s;
    $main_without_arm_sync =~ s/sub _spark_sync_sender_arm \{.*?
\}//s;
    $assert->unlike($main_without_arm_sync, qr/->arm\s*\(|ConversationSender::arm\s*\(/,
        'mb701-934: production runtime has no sender arm path outside the dedicated helper');
};
