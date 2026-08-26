# t/cases/925_mb700_wit_dryrun_observer.t
# =============================================================================
# MB700-C — +Wit public observation is dry-run only.
# =============================================================================

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::AI::ConversationObserver qw(
    is_command_like
    observe_public_line
    format_dryrun_log
);

return sub {
    my ($assert) = @_;

    $assert->ok(is_command_like(message => '!help', command_char => '!'),
        'mb700-925: normal command prefix is excluded from Wit consideration');
    $assert->ok(is_command_like(message => '?coffee'),
        'mb700-925: bare factoid quick recall is command-like');
    $assert->ok(is_command_like(message => 'mediabotv3: hello', bot_nick => 'mediabotv3'),
        'mb700-925: direct nick-addressed command form is excluded');
    $assert->ok(is_command_like(
        message => 'm tellme hello', bot_nick => 'mediabotv3', initial_trigger_enabled => 1,
    ), 'mb700-925: configured initial-trigger command form is excluded');
    $assert->ok(!is_command_like(
        message => 'maybe this is normal', bot_nick => 'mediabotv3', initial_trigger_enabled => 0,
    ), 'mb700-925: normal conversation stays non-command');

    my $off = observe_public_line(
        enabled => 0, channel => '#test', nick => 'Alice', bot_nick => 'mediabotv3',
        message => 'bonjour tout le monde', language => 'fr', command_char => '!', now => 100,
    );
    $assert->is($off->{action}, 'no_reply',
        'mb700-925: pure observer preserves fail-closed disabled policy');
    $assert->is($off->{reason}, 'disabled',
        'mb700-925: disabled reason remains explicit');

    my $out = observe_public_line(
        enabled => 1, channel => '#test', nick => 'Alice', bot_nick => 'mediabotv3',
        message => 'bonjour tout le monde', language => 'fr', command_char => '!', now => 100,
    );
    $assert->is($out->{action}, 'consider',
        'mb700-925: enabled public human line reaches mechanical consideration');
    $assert->is($out->{reason}, 'eligible',
        'mb700-925: eligible reason is preserved');
    $assert->is($out->{language}, 'fr',
        'mb700-925: supplied channel language is preserved');
    $assert->is($out->{provider}, 'auto',
        'mb700-925: dry-run stays provider-neutral');
    $assert->ok(!exists($out->{message}) && !exists($out->{nick}) && !exists($out->{channel}),
        'mb700-925: result retains no message, nick or channel identity');

    my $log = format_dryrun_log('#test', $out);
    $assert->is(
        $log,
        '[WIT_DRYRUN] channel=#test action=consider reason=eligible language=fr provider=auto',
        'mb700-925: dry-run log contains bounded operational metadata only',
    );
    $assert->unlike($log, qr/Alice|bonjour|tout le monde/i,
        'mb700-925: dry-run log contains neither nick nor message content');

    my $cmd = observe_public_line(
        enabled => 1, channel => '#test', nick => 'Alice', bot_nick => 'mediabotv3',
        message => 'm tellme secret words', language => 'fr', command_char => '!',
        initial_trigger_enabled => 1, now => 101,
    );
    $assert->is($cmd->{action}, 'no_reply',
        'mb700-925: command-shaped input is observed only as no_reply');
    $assert->is($cmd->{reason}, 'command',
        'mb700-925: command reason is explicit');
    $assert->unlike(format_dryrun_log('#test', $cmd), qr/secret words|Alice/i,
        'mb700-925: command rejection log remains payload/identity free');

    my $self_line = observe_public_line(
        enabled => 1, channel => '#test', nick => 'MediaBotV3', bot_nick => 'mediabotv3',
        message => 'hello', language => 'en', now => 102,
    );
    $assert->is($self_line->{reason}, 'self',
        'mb700-925: self nick comparison is case-insensitive');

    my $summary = {
        action => 'no_reply', reason => 'cooldown', language => 'es',
        provider => 'openai', retry_after_seconds => 12,
    };
    $assert->is(
        format_dryrun_log('#test', $summary),
        '[WIT_DRYRUN] channel=#test action=no_reply reason=cooldown language=es provider=openai retry_after=12',
        'mb700-925: optional retry metadata is bounded and explicit',
    );

    my $observer = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../Mediabot/AI/ConversationObserver.pm" or die $!;
        local $/; <$fh>;
    };
    $assert->unlike($observer, qr/AI::Client|Provider::Anthropic|Provider::OpenAI|HTTP::|DBI\b|CHANNEL_SET|CHANSET_LIST|botPrivmsg|botNotice|botAction/,
        'mb700-925: observer owns no provider, HTTP, DB/chanset storage or IRC emission');
    $assert->like($observer, qr/evaluate_candidate\s*\(/,
        'mb700-925: observer delegates the mechanical decision to ConversationPolicy');

    my $main = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../mediabot.pl" or die $!;
        local $/; <$fh>;
    };
    $assert->like($main, qr/use Mediabot::AI::ConversationObserver \(\);/,
        'mb700-925: main runtime loads the observer explicitly');
    $assert->like($main, qr/chanset_enabled\s*\(\s*\$mediabot,\s*\$where,\s*'Wit',\s*default\s*=>\s*0/s,
        'mb700-925: runtime hook is default-off behind +Wit');
    $assert->like($main, qr/Mediabot::AI::ConversationDryRun->new\(.*?conf\s*=>\s*\$mediabot->\{conf\}.*?loop_owner\s*=>\s*\$mediabot/s,
        'mb700-925: runtime delegates provider-capable dry-run work to the dedicated orchestrator');
    $assert->like($main, qr/handle_public_line\(.*?message\s*=>\s*\$line.*?language\s*=>\s*Mediabot::Helpers::channel_lang/s,
        'mb700-925: normalized public line and channel language feed the dry-run orchestrator');
    $assert->like($main, qr/format_dryrun_log\(\s*\$where,\s*\$wit_summary/s,
        'mb700-925: runtime keeps logging only observer summary metadata');

    my ($hook) = $main =~ /(\# mb700-G: \+Wit remains explicit opt-in and dry-run only,.*?my \(\$sCommand,\@tArgs\))/s;
    $hook //= '';
    $assert->unlike($hook, qr/botPrivmsg|botNotice|botAction|Mediabot::AI::Client|chatGPT|claudeAI/,
        'mb700-925: main dry-run hook contains no IRC emission or direct provider client call');
};
