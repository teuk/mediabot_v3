# t/cases/926_mb700_wit_model_decision_contract.t
# =============================================================================
# MB700-D — strict model decision contract for future +Wit execution.
#
# No provider is called here. The parser accepts only NO_REPLY or a bounded,
# single-line REPLY: payload and fails closed for everything else.
# =============================================================================

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::AI::ConversationDecision qw(
    decision_defaults
    decision_contract
    parse_model_decision
    decision_summary
);

return sub {
    my ($assert) = @_;

    my $defaults = decision_defaults();
    $assert->is($defaults->{max_reply_chars}, 280,
        'mb700-926: default reply budget is IRC-brief');
    $assert->is($defaults->{max_raw_chars}, 4096,
        'mb700-926: raw model output has a hard parsing ceiling');

    my $contract = decision_contract();
    $assert->like($contract, qr/\bNO_REPLY\b/,
        'mb700-926: wire contract names the explicit no-reply token');
    $assert->like($contract, qr/REPLY: <single-line reply>/,
        'mb700-926: wire contract requires an explicit one-line reply prefix');
    $assert->like($contract, qr/Do not use Markdown, JSON, code fences, labels or extra lines\./,
        'mb700-926: wire contract forbids ambiguous wrappers');

    my $d = parse_model_decision('NO_REPLY');
    $assert->is($d->{action}, 'no_reply',
        'mb700-926: exact NO_REPLY is accepted');
    $assert->is($d->{reason}, 'model_no_reply',
        'mb700-926: model abstention remains explicit');
    $assert->ok(!exists($d->{text}),
        'mb700-926: no-reply decision carries no text');

    $d = parse_model_decision("  NO_REPLY \t");
    $assert->is($d->{reason}, 'model_no_reply',
        'mb700-926: harmless outer whitespace is tolerated');

    $d = parse_model_decision('REPLY: Bonjour tout le monde 👋');
    $assert->is($d->{action}, 'reply',
        'mb700-926: explicit REPLY payload is accepted');
    $assert->is($d->{reason}, 'model_reply',
        'mb700-926: accepted reply reason is explicit');
    $assert->is($d->{text}, 'Bonjour tout le monde 👋',
        'mb700-926: Unicode reply text is preserved');

    $d = parse_model_decision("REPLY: \x02Bonjour\x02 \x0304rouge\x0f");
    $assert->is($d->{text}, 'Bonjour rouge',
        'mb700-926: IRC formatting controls are stripped before future emission');

    for my $bad (
        undef,
        [],
        '',
        'no_reply',
        'NO_REPLY because nobody asked me',
        'Here is my answer',
        'REPLY:',
        "REPLY: first line\nsecond line",
        "```\nNO_REPLY\n```",
        '{"action":"NO_REPLY"}',
    ) {
        my $bad_d = parse_model_decision($bad);
        $assert->is($bad_d->{action}, 'no_reply',
            'mb700-926: malformed/ambiguous output fails closed');
        $assert->is($bad_d->{reason}, 'invalid_output',
            'mb700-926: malformed output is classified as invalid_output');
    }

    $d = parse_model_decision('REPLY: ' . ('x' x 281));
    $assert->is($d->{action}, 'no_reply',
        'mb700-926: oversized reply fails closed');
    $assert->is($d->{reason}, 'reply_too_long',
        'mb700-926: oversized reply has a distinct machine reason');
    $assert->ok(!exists($d->{text}),
        'mb700-926: oversized reply content is not retained');

    $d = parse_model_decision('REPLY: ' . ('x' x 40), max_reply_chars => 32);
    $assert->is($d->{reason}, 'reply_too_long',
        'mb700-926: safe caller reply budget may tighten the default');

    $d = parse_model_decision('REPLY: ' . ('x' x 100), max_reply_chars => 5);
    $assert->is($d->{action}, 'reply',
        'mb700-926: unsafe tiny budget falls back to conservative default');

    $d = parse_model_decision('x' x 4097);
    $assert->is($d->{reason}, 'invalid_output',
        'mb700-926: oversized raw output is rejected before interpretation');

    my $summary = decision_summary({
        action => 'reply', reason => 'model_reply', text => " hello   world ",
        raw => 'must not escape', prompt => 'must not escape', nick => 'Alice',
    });
    $assert->is($summary->{text}, 'hello world',
        'mb700-926: normalized reply summary remains bounded and clean');
    $assert->ok(!exists($summary->{raw}) && !exists($summary->{prompt}) && !exists($summary->{nick}),
        'mb700-926: summary does not expose raw model output, prompt or identity');

    $assert->ok(!defined(decision_summary({ action => 'consider', reason => 'eligible' })),
        'mb700-926: model decision layer cannot return mechanical consider');
    $assert->ok(!defined(decision_summary({ action => 'reply', reason => 'model_reply', text => ('x' x 281) })),
        'mb700-926: summary refuses replies above the canonical bound');

    my $src = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../Mediabot/AI/ConversationDecision.pm" or die $!;
        local $/; <$fh>;
    };
    $assert->unlike($src, qr/AI::Client|Provider::Anthropic|Provider::OpenAI|HTTP::|DBI\b|CHANNEL_SET|CHANSET_LIST|botPrivmsg|botNotice|botAction/,
        'mb700-926: decision contract owns no provider, HTTP, DB or IRC emission');

    my $main = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../mediabot.pl" or die $!;
        local $/; <$fh>;
    };
    $assert->unlike($main, qr/use Mediabot::AI::ConversationDecision/,
        'mb700-926: MB700-D contract is not wired into runtime yet');
};
