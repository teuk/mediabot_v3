# t/cases/808_mb625_summary_recap_precommit_truth.t
# =============================================================================
# mb625 — pre-commit truthfulness for the strict summary/recap parsers.
#
# Locks the points found during the final review:
#   * no round/test-number collision with the committed news mb618/mb619 arc;
#   * documented ai-summary ranges are enforced rather than silently clamped;
#   * a count cannot be accepted then ignored when a period is present;
#   * duplicate language/nick/count selectors are rejected;
#   * the <N>h service label exists in EN/FR/ES;
#   * capped sampling renders "1500+ messages" in the right place;
#   * today/yesterday predicates keep the channel/time index usable;
#   * recap rejects an unsupported language even on the stats path.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

return sub {
    my ($assert) = @_;

    require Mediabot::External::Claude;
    require Mediabot::UserCommands;

    my $C = 'Mediabot::External::Claude';
    my $P = $C->can('_summary_parse');
    $assert->ok($P, 'mb625-808: summary parser is callable');

    # [1] The documented ranges are real parser contracts.
    for my $bad (qw(0h 73h 0d 31d 4 51 0l 11l)) {
        my $o = $P->($bad);
        $assert->is(scalar @{ $o->{invalid} }, 1,
            "mb625-808: '$bad' is rejected instead of silently clamped");
    }
    for my $good (qw(1h 72h 1d 30d 5 50 1l 10l)) {
        my $o = $P->($good);
        $assert->is(scalar @{ $o->{invalid} }, 0,
            "mb625-808: boundary '$good' is accepted");
    }

    my $o = $P->(qw(today 20));
    $assert->is(scalar @{ $o->{invalid} }, 1,
        'mb625-808: bare message count with a period is not accepted then ignored');

    $o = $P->(qw(20 30));
    $assert->is(scalar @{ $o->{duplicate} }, 1,
        'mb625-808: duplicate message counts are rejected');
    $o = $P->(qw(fr en));
    $assert->is(scalar @{ $o->{duplicate} }, 1,
        'mb625-808: duplicate language selectors are rejected');
    $o = $P->('nick=teuk', 'saya');
    $assert->is(scalar @{ $o->{duplicate} }, 1,
        'mb625-808: nick= plus a positional nick is rejected');

    # [2] Hours are visible to the user, not only to SQL/the model.
    my $label = $C->can('_summary_period_label');
    $assert->is($label->('en', 'hours', 6), ' (last 6h)',
        'mb625-808: English hour label');
    $assert->is($label->('fr', 'hours', 6), ' (depuis 6h)',
        'mb625-808: French hour label');
    $assert->is($label->('es', 'hours', 6), ' (ultimas 6h)',
        'mb625-808: Spanish hour label');

    my $strings = $C->can('_summary_lang_strings');
    $assert->is(sprintf($strings->('fr')->{sampled}, 1500, '+', 400),
        '1500+ messages sur la periode - resume sur un echantillon reparti de 400.',
        'mb625-808: safety-cap plus sign belongs after the number');

    # [3] Structural runtime guards.
    my $csrc = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/External/Claude.pm'
        or die $!; local $/; <$fh> };
    $assert->ok($csrc !~ /DATE\(cl\.ts\)\s*=\s*CURDATE/,
        'mb625-808: today/yesterday no longer wrap indexed ts in DATE()');
    $assert->like($csrc,
        qr/cl\.ts >= CURDATE\(\) AND cl\.ts < CURDATE\(\) \+ INTERVAL 1 DAY/,
        'mb625-808: today uses an index-friendly half-open timestamp range');
    $assert->like($csrc,
        qr/cl\.ts >= CURDATE\(\) - INTERVAL 1 DAY AND cl\.ts < CURDATE\(\)/,
        'mb625-808: yesterday uses an index-friendly half-open timestamp range');

    my $usrc = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/UserCommands.pm'
        or die $!; local $/; <$fh> };
    $assert->like($usrc,
        qr/if \(defined \$bad_lang\) \{.*?unsupported language.*?return;/s,
        'mb625-808: recap unsupported language fails closed before stats/AI work');

    # [4] History/test numbering stays unique after the committed news arc.
    $assert->ok(-f 't/cases/801_mb618_news_precise_rss_articles.t',
        'mb625-808: committed news test 801 remains');
    $assert->ok(-f 't/cases/802_mb619_news_fresh_relevant_headlines.t',
        'mb625-808: committed news test 802 remains');
    $assert->ok(-f 't/cases/806_mb623_ai_summary_syntax.t',
        'mb625-808: ai-summary test moved to 806/mb623');
    $assert->ok(-f 't/cases/807_mb624_recap_strict_syntax.t',
        'mb625-808: recap test moved to 807/mb624');
    $assert->ok(!-e 't/cases/801_mb618_ai_summary_syntax.t'
             && !-e 't/cases/802_mb619_recap_strict_syntax.t',
        'mb625-808: duplicate 801/802 filenames are gone');

    my $chg = do { open my $fh, '<:encoding(UTF-8)', 'CHANGELOG.md'
        or die $!; local $/; <$fh> };
    for my $round (618, 619, 623, 624, 625) {
        my $n = () = $chg =~ /^### mb$round\b/mg;
        $assert->is($n, 1, "mb625-808: changelog has exactly one mb$round heading");
    }
};
