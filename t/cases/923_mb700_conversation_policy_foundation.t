# t/cases/923_mb700_conversation_policy_foundation.t
# =============================================================================
# MB700-A — fail-closed mechanical conversation policy for future +Wit.
#
# This layer decides only whether a public human line may be CONSIDERED by a
# future AI decision layer. It never forces a reply and owns no IRC, HTTP, DB,
# worker, randomness or conversation persistence.
# =============================================================================

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::AI::ConversationPolicy qw(
    policy_defaults
    evaluate_candidate
    decision_summary
);

return sub {
    my ($assert) = @_;

    my $defaults = policy_defaults();
    $assert->is($defaults->{min_interval_seconds}, 90,
        'mb700-923: conservative default cooldown is 90 seconds');
    $assert->is($defaults->{max_message_chars}, 800,
        'mb700-923: provider consideration has a bounded input ceiling');

    my $base = {
        enabled       => 1,
        channel       => '#test',
        message       => 'hello there',
        language      => 'fr',
        provider      => 'auto',
        from_self     => 0,
        from_bot      => 0,
        is_command    => 0,
        now           => 200,
        last_reply_at => 0,
    };

    my $decision = evaluate_candidate(%$base, enabled => 0);
    $assert->is($decision->{action}, 'no_reply',
        'mb700-923: Wit policy fails closed when disabled');
    $assert->is($decision->{reason}, 'disabled',
        'mb700-923: disabled reason is machine-visible');

    $decision = evaluate_candidate(%$base, channel => 'Te[u]K');
    $assert->is($decision->{reason}, 'private',
        'mb700-923: private targets are rejected');

    $decision = evaluate_candidate(%$base, from_self => 1);
    $assert->is($decision->{reason}, 'self',
        'mb700-923: bot never reacts to its own line');

    $decision = evaluate_candidate(%$base, from_bot => 1);
    $assert->is($decision->{reason}, 'bot',
        'mb700-923: bot-authored lines are ignored');

    $decision = evaluate_candidate(%$base, is_command => 1);
    $assert->is($decision->{reason}, 'command',
        'mb700-923: commands do not enter proactive Wit consideration');

    $decision = evaluate_candidate(%$base, message => "   \t  ");
    $assert->is($decision->{reason}, 'empty',
        'mb700-923: whitespace-only input is rejected');

    $decision = evaluate_candidate(%$base, message => ('x' x 801));
    $assert->is($decision->{reason}, 'too_long',
        'mb700-923: oversized input is rejected before any AI call');

    $decision = evaluate_candidate(
        %$base,
        now                  => 130,
        last_reply_at        => 100,
        min_interval_seconds => 90,
    );
    $assert->is($decision->{reason}, 'cooldown',
        'mb700-923: recent bot activity blocks consideration');
    $assert->is($decision->{retry_after_seconds}, 60,
        'mb700-923: cooldown exposes bounded retry information');

    $decision = evaluate_candidate(
        %$base,
        now                  => 190,
        last_reply_at        => 100,
        min_interval_seconds => 90,
    );
    $assert->is($decision->{action}, 'consider',
        'mb700-923: cooldown boundary becomes eligible');
    $assert->is($decision->{reason}, 'eligible',
        'mb700-923: eligible is consideration, not a forced reply');
    $assert->is($decision->{language}, 'fr',
        'mb700-923: channel language is carried as policy metadata');
    $assert->is($decision->{provider}, 'auto',
        'mb700-923: provider-neutral auto policy is preserved');

    $decision = evaluate_candidate(%$base, language => 'xx', provider => 'Claude');
    $assert->is($decision->{language}, 'en',
        'mb700-923: unknown language fails to English');
    $assert->is($decision->{provider}, 'anthropic',
        'mb700-923: provider aliases use the central AI registry');

    $decision = evaluate_candidate(%$base, provider => 'definitely-not-a-provider');
    $assert->is($decision->{action}, 'no_reply',
        'mb700-923: unknown provider fails closed');
    $assert->is($decision->{reason}, 'invalid_provider',
        'mb700-923: invalid provider reason is explicit');

    $decision = evaluate_candidate(
        %$base,
        max_message_chars    => 10,
        min_interval_seconds => 99999,
        message              => ('x' x 100),
        now                  => 200,
        last_reply_at        => 0,
    );
    $assert->is($decision->{reason}, 'eligible',
        'mb700-923: unsafe numeric overrides fall back to conservative defaults');

    my $summary = decision_summary({
        action              => 'no_reply',
        reason              => 'cooldown',
        language            => 'es',
        provider            => 'GPT',
        retry_after_seconds => 12,
        message             => 'must not escape',
        nick                => 'must not escape',
        api_key             => 'must not escape',
    });
    $assert->is($summary->{provider}, 'openai',
        'mb700-923: summaries normalize provider aliases');
    $assert->is($summary->{language}, 'es',
        'mb700-923: summaries preserve supported language');
    $assert->is($summary->{retry_after_seconds}, 12,
        'mb700-923: summaries keep safe retry metadata');
    $assert->ok(!exists($summary->{message}) && !exists($summary->{nick}) && !exists($summary->{api_key}),
        'mb700-923: summaries never expose message, identity or credentials');

    $assert->ok(!defined(decision_summary({ action => 'reply', reason => 'forced' })),
        'mb700-923: policy cannot manufacture a direct reply action');

    my $path = "$Bin/../../Mediabot/AI/ConversationPolicy.pm";
    open my $fh, '<:encoding(UTF-8)', $path or die "open $path: $!";
    local $/;
    my $src = <$fh>;
    close $fh;

    $assert->unlike($src, qr/\b(?:HTTP::|DBI\b|AsyncWorker\b|botPrivmsg\b|botNotice\b|send_message\b)/,
        'mb700-923: ConversationPolicy owns no transport, DB, worker or IRC delivery');
    $assert->unlike($src, qr/\brand\s*\(/,
        'mb700-923: mechanical policy is deterministic and owns no randomness');

    my $eligible = evaluate_candidate(%$base);
    $assert->is($eligible->{action}, 'consider',
        'mb700-923: normal public human text may be considered');
    $assert->ok(!exists($eligible->{message}) && !exists($eligible->{channel}),
        'mb700-923: decision object does not retain conversation content or channel identity');
};
