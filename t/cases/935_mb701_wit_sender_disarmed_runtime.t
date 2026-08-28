# t/cases/935_mb701_wit_sender_disarmed_runtime.t
# =============================================================================
# MB701-D-B — production runtime sender wiring remains disarmed and metadata-only.
# =============================================================================

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::AI::ConversationSender qw(format_sender_log);

return sub {
    my ($assert) = @_;

    my $main = do {
        open my $mf, '<:encoding(UTF-8)', "$Bin/../../mediabot.pl"
            or die "open mediabot.pl: $!";
        local $/;
        <$mf>;
    };

    $assert->like($main, qr/use Mediabot::AI::ConversationSender \(\);/,
        'mb701-935: production runtime imports the dedicated sender');
    $assert->like($main, qr/ConversationSender->new\s*\(/,
        'mb701-935: runtime creates a sender only at the dedicated boundary');
    $assert->like($main, qr/->attempt_send\s*\(/,
        'mb701-935: authorized dry-run candidates reach the sender contract');
    $assert->like($main, qr/ConversationSender::format_sender_log\s*\(/,
        'mb701-935: runtime logs only sender metadata');
    my ($arm_sync) = $main =~ /(sub _wit_sync_sender_arm \{.*?
\})/s;
    $assert->ok(defined($arm_sync),
        'mb701-935: D-C confines arm/disarm to a dedicated config synchronization helper');
    my $main_without_arm_sync = $main;
    $main_without_arm_sync =~ s/sub _wit_sync_sender_arm \{.*?
\}//s;
    $main_without_arm_sync =~ s/sub _spark_sync_sender_arm \{.*?
\}//s;
    $assert->unlike($main_without_arm_sync, qr/->arm\s*\(|ConversationSender::arm\s*\(/,
        'mb701-935: no sender arm path exists outside the dedicated synchronization helper');

    my ($wit_block) = $main =~ /(\# mb700-G: \+Wit.*?)(?=\n\s*my \(\$sCommand,\@tArgs\))/s;
    $assert->ok(defined($wit_block),
        'mb701-935: proactive Wit runtime block is identifiable');
    $assert->unlike($wit_block // q{}, qr/\b(?:botPrivmsg|botNotice|send_message|do_PRIVMSG)\b/,
        'mb701-935: proactive callback block still contains no direct IRC primitive');
    $assert->like($wit_block // q{}, qr/\(\$emit_summary->\{action\} \/\/ q\{\}\) eq 'emit'/,
        'mb701-935: sender is attempted only after late emission authorization');
    $assert->like($wit_block // q{}, qr/state_cb\s*=>\s*\$wit_state_cb/,
        'mb701-935: sender receives the late mutable-state callback for final revalidation');

    my ($transport) = $main =~ /(sub _wit_send_transport \{.*?\n\})/s;
    $assert->ok(defined($transport),
        'mb701-935: the sole concrete Wit transport helper is isolated from the callback block');
    my $primitive_count = () = (($transport // q{}) =~ /Mediabot::Helpers::botPrivmsg\s*\(/g);
    $assert->is($primitive_count, 1,
        'mb701-935: transport helper contains exactly one normal IRC PRIVMSG primitive');
    $assert->unlike($transport // q{}, qr/do_PRIVMSG|botNotice|botAction|send_message/,
        'mb701-935: transport helper cannot bypass the normal botPrivmsg output path');

    my $decl_count = () = ($main =~ /sub _wit_send_transport;/g);
    my $def_count = () = ($main =~ /sub _wit_send_transport \{/g);
    my $call_count = () = ($main =~ /return _wit_send_transport\(/g);
    $assert->is($decl_count, 1,
        'mb701-935: transport helper has one forward declaration');
    $assert->is($def_count, 1,
        'mb701-935: transport helper has one implementation');
    $assert->is($call_count, 1,
        'mb701-935: transport helper is injected at exactly one sender callback');

    # The actual sender object is disarmed by construction. Even with a fully
    # authorized mutable state, the injected transport must remain untouched.
    my $send_calls = 0;
    my $state_calls = 0;
    my $sender = Mediabot::AI::ConversationSender->new(
        send_cb => sub { $send_calls++; return 1; },
    );
    $assert->is($sender->is_armed(), 0,
        'mb701-935: runtime-equivalent sender starts disarmed');

    my $result = $sender->attempt_send(
        channel            => '#test',
        text               => 'Réponse autorisée en dry-run seulement.',
        request_generation => 7,
        state_cb            => sub {
            $state_calls++;
            return {
                enabled            => 1,
                runtime_active     => 1,
                irc_connected      => 1,
                channel_joined     => 1,
                current_generation => 7,
            };
        },
    );

    $assert->is($result->{action}, 'no_send',
        'mb701-935: authorized candidate remains a no-send while runtime sender is disarmed');
    $assert->is($result->{reason}, 'kill_switch',
        'mb701-935: independent sender kill switch is the live D-B blocker');
    $assert->is($state_calls, 0,
        'mb701-935: disarmed sender refuses before consulting mutable runtime state');
    $assert->is($send_calls, 0,
        'mb701-935: disarmed sender never reaches the injected IRC transport');
    $assert->ok(!exists($result->{text}),
        'mb701-935: sender result never exposes candidate text');

    my $log = format_sender_log('#test', $result);
    $assert->is($log,
        '[WIT_SEND] channel=#test action=no_send reason=kill_switch',
        'mb701-935: disarmed runtime produces a deterministic metadata-only WIT_SEND log');
    $assert->unlike($log, qr/Réponse|autorisée|dry-run/,
        'mb701-935: WIT_SEND log contains no generated candidate text');
};
