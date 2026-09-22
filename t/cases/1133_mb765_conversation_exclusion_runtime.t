# MB765 — the exclusion boundary precedes every public interaction lane.

use strict;
use warnings;
use utf8;

sub slurp_1133 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $main = slurp_1133('mediabot.pl');
    $assert->like($main,
        qr/use Mediabot::AI::ConversationExclusion \(\);/,
        'main runtime loads the central exclusion policy');

    my $start = index($main, 'sub _on_message_PRIVMSG_body');
    my $end = index($main, 'sub on_message_ctcp_CHAT', $start);
    $assert->ok($start >= 0 && $end > $start,
        'public PRIVMSG implementation is available for ordering checks');
    my $body = substr($main, $start, $end - $start);
    my $barrier = index($body, 'my $conversation_exclusion;');
    my $drop = index($body, "'[CONVERSATION_IGNORE] channel='");
    $assert->ok($barrier >= 0 && $drop > $barrier,
        'runtime evaluates and records the shared barrier');

    for my $later (
        'updateUserSeen(',
        'deliverReminders(',
        'checkTriviaAnswer(',
        'checkQuotegameAnswer(',
        'queue_check(',
        'hailo_observe_public_line(',
        '_spark_observe_public_line(',
        'handle_public_line(',
        'mbCommandPublic(',
        'displayUrlTitle(',
        'checkResponder(',
        'hailo_record_activity(',
        'hailo_process_turn(',
    ) {
        my $position = index($body, $later);
        $assert->ok($position > $drop,
            "exclusion return precedes $later");
    }

    $assert->like($body,
        qr/return undef;\s*\}\s*\n\s*# Track last seen/s,
        'excluded traffic returns before public state mutation');
    $assert->like($body,
        qr/Conversation exclusion error:.*?substr\(\$error, 0, 200\)/s,
        'classifier faults are sanitized and bounded');
    $assert->unlike($body,
        qr/\[CONVERSATION_IGNORE\].*?(?:message|text|payload)=/,
        'exclusion diagnostic carries no message payload field');

    my $metrics = slurp_1133('Mediabot/Metrics.pm');
    $assert->like($metrics,
        qr/mediabot_conversation_excluded_total.*?\['reason'\]/s,
        'aggregate exclusion counter has only the bounded reason label');
    $assert->like($body,
        qr/reason =~ \/\\A\(\?:declared_bot\|bot_address\|bot_command\)\\z\//,
        'runtime clamps reasons to the fixed vocabulary');
};
