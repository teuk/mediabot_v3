# t/cases/930_mb701_wit_emission_contract.t
# =============================================================================
# MB701-A — pure, fail-closed final emission authorization contract for +Wit.
# No IRC delivery is possible in this round.
# =============================================================================

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::AI::ConversationEmission qw(
    emission_defaults
    evaluate_emission
    emission_summary
);

return sub {
    my ($assert) = @_;

    my $defaults = emission_defaults();
    $assert->is($defaults->{max_reply_chars}, 280,
        'mb701-930: emission keeps the strict 280-character ceiling');
    $assert->is($defaults->{max_reply_bytes}, 350,
        'mb701-930: proactive output must fit one conservative IRC wire budget');

    my %base = (
        enabled            => 1,
        runtime_active     => 1,
        irc_connected      => 1,
        channel_joined     => 1,
        request_generation => 7,
        current_generation => 7,
        channel            => '#test',
        text               => 'Salut depuis la tour des hiboux.',
    );

    my $decision = evaluate_emission(%base, enabled => 0);
    $assert->is($decision->{action}, 'no_emit',
        'mb701-930: late +Wit opt-out always prevents emission');
    $assert->is($decision->{reason}, 'disabled',
        'mb701-930: opt-out reason is machine-visible');

    $decision = evaluate_emission(%base, runtime_active => 0);
    $assert->is($decision->{reason}, 'runtime_inactive',
        'mb701-930: shutdown/inactive runtime prevents late emission');

    $decision = evaluate_emission(%base, irc_connected => 0);
    $assert->is($decision->{reason}, 'irc_disconnected',
        'mb701-930: disconnected IRC transport fails closed');

    $decision = evaluate_emission(%base, channel_joined => 0);
    $assert->is($decision->{reason}, 'not_joined',
        'mb701-930: bot must still be joined at emission time');

    $decision = evaluate_emission(%base, request_generation => 6);
    $assert->is($decision->{reason}, 'stale_generation',
        'mb701-930: stale async result cannot cross a channel generation change');

    $decision = evaluate_emission(%base, request_generation => undef);
    $assert->is($decision->{reason}, 'stale_generation',
        'mb701-930: missing request generation fails closed');

    $decision = evaluate_emission(%base, current_generation => 0);
    $assert->is($decision->{reason}, 'stale_generation',
        'mb701-930: generation zero is never a valid live authorization token');

    $decision = evaluate_emission(%base, channel => 'Alice');
    $assert->is($decision->{reason}, 'invalid_channel',
        'mb701-930: private targets can never be proactive emission targets');

    $decision = evaluate_emission(%base, text => "hello\nPRIVMSG #other :oops");
    $assert->is($decision->{reason}, 'unsafe_reply',
        'mb701-930: CR/LF framing injection is rejected, never repaired');

    $decision = evaluate_emission(%base, text => "\x01ACTION nope\x01");
    $assert->is($decision->{reason}, 'unsafe_reply',
        'mb701-930: CTCP/control payloads cannot be emitted by Wit');

    $decision = evaluate_emission(%base, text => "\x02 \x0f\x03");
    $assert->is($decision->{reason}, 'empty_reply',
        'mb701-930: formatting-only output becomes empty and is rejected');

    $decision = evaluate_emission(%base, text => "\x02Salut\x0f  \x0304les hiboux");
    $assert->is($decision->{action}, 'emit',
        'mb701-930: ordinary IRC presentation codes are removed defensively');
    $assert->is($decision->{text}, 'Salut les hiboux',
        'mb701-930: sanitized plain text is the only candidate for later delivery');

    $decision = evaluate_emission(%base, text => ('x' x 281));
    $assert->is($decision->{reason}, 'reply_too_long',
        'mb701-930: character ceiling fails closed without truncation');
    $assert->is($decision->{reply_chars}, 281,
        'mb701-930: rejected oversize reply exposes only safe size metadata');

    $decision = evaluate_emission(%base, text => ('🙂' x 100));
    $assert->is($decision->{reason}, 'reply_too_large',
        'mb701-930: multibyte reply exceeding one-wire budget is rejected');
    $assert->is($decision->{reply_chars}, 100,
        'mb701-930: Unicode character count remains distinct from wire bytes');
    $assert->ok($decision->{reply_bytes} > 350,
        'mb701-930: UTF-8 byte budget is enforced on encoded payload size');

    $decision = evaluate_emission(%base, text => 'Un petit sort 🙂');
    $assert->is($decision->{action}, 'emit',
        'mb701-930: safe bounded Unicode text can be authorized');
    $assert->is($decision->{reason}, 'authorized',
        'mb701-930: positive result is authorization, not delivery');
    $assert->is($decision->{request_generation}, 7,
        'mb701-930: authorized result carries the generation it was checked against');
    $assert->ok($decision->{reply_bytes} >= $decision->{reply_chars},
        'mb701-930: safe reply metadata records both characters and bytes');

    my $summary = emission_summary($decision);
    $assert->is($summary->{action}, 'emit',
        'mb701-930: safe summary preserves authorization action');
    $assert->is($summary->{reason}, 'authorized',
        'mb701-930: safe summary preserves reason');
    $assert->ok(!exists($summary->{text}),
        'mb701-930: emission summary never exposes generated reply text');
    $assert->is($summary->{reply_chars}, $decision->{reply_chars},
        'mb701-930: summary keeps safe reply length metadata');
    $assert->is($summary->{reply_bytes}, $decision->{reply_bytes},
        'mb701-930: summary keeps safe wire-size metadata');
    $assert->is($summary->{request_generation}, 7,
        'mb701-930: summary keeps the safe generation token');

    my $croaked = 0;
    eval { evaluate_emission(%base, api_key => 'must-not-be-accepted') };
    $croaked = $@ ? 1 : 0;
    $assert->ok($croaked,
        'mb701-930: unknown/sensitive caller fields are rejected explicitly');

    my $limit_override_croaked = 0;
    eval { evaluate_emission(%base, max_reply_bytes => 400) };
    $limit_override_croaked = $@ ? 1 : 0;
    $assert->ok($limit_override_croaked,
        'mb701-930: callers cannot relax the fixed proactive wire budget');

    my $path = "$Bin/../../Mediabot/AI/ConversationEmission.pm";
    open my $fh, '<:encoding(UTF-8)', $path or die "open $path: $!";
    local $/;
    my $src = <$fh>;
    close $fh;

    $assert->unlike($src, qr/\b(?:DBI|CHANNEL_SET|CHANSET_LIST|botPrivmsg|botNotice|send_message|do_PRIVMSG)\b/,
        'mb701-930: emission contract owns no DB/chanset/IRC delivery primitive');
    $assert->unlike($src, qr/Mediabot::Helpers|Net::Async::IRC|ConversationExecutor/,
        'mb701-930: pure final gate has no runtime/helper/provider dependency');

    my $main = do {
        open my $mf, '<:encoding(UTF-8)', "$Bin/../../mediabot.pl"
            or die "open mediabot.pl: $!";
        local $/;
        <$mf>;
    };
    $assert->like($main, qr/use Mediabot::AI::ConversationEmission \(\);/,
        'mb701-930: later MB701 runtime may import the pure final gate');
    my ($wit_block) = $main =~ /(\# mb700-G: \+Wit.*?)(?=
\s*my \(\$sCommand,\@tArgs\))/s;
    $assert->ok(defined($wit_block),
        'mb701-930: proactive Wit runtime block remains identifiable');
    $assert->unlike($wit_block // '', qr/(?:botPrivmsg|botNotice|send_message|do_PRIVMSG)/,
        'mb701-930: final authorization wiring still has no IRC delivery primitive');
};
