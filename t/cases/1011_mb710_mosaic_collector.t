use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use Mediabot::Spark::Mosaic qw(
    mosaic_target_for_regime
    mosaic_opening_generation
);

return sub {
    my ($assert) = @_;

    $assert->is(mosaic_target_for_regime('small'), 2,
        'mb710-1011: small rooms ask for two voices');
    $assert->is(mosaic_target_for_regime('social'), 3,
        'mb710-1011: social rooms ask for three voices');
    $assert->is(mosaic_target_for_regime('crowded'), 4,
        'mb710-1011: crowded rooms ask for four voices');
    $assert->ok(!defined mosaic_target_for_regime('solo'),
        'mb710-1011: solo rooms cannot open a collective Mosaic');

    my $opening = mosaic_opening_generation(language => 'fr', target => 4);
    $assert->is($opening->{kind}, 'mosaic',
        'mb710-1011: deterministic opener stays inside the Mosaic family');
    $assert->like($opening->{content}{line}, qr/\+mot.*4 voix/i,
        'mb710-1011: opener states explicit syntax and audience-sized target');

    my $now = 10_000;
    my $mosaic = Mediabot::Spark::Mosaic->new(clock => sub { $now });
    my $begin = $mosaic->begin(
        channel => '#spark', generation => 71, target => 2,
    );
    $assert->is($begin->{action}, 'begin',
        'mb710-1011: collector starts on one explicit event generation');
    $assert->is($mosaic->snapshot('#SPARK')->{target}, 2,
        'mb710-1011: per-event target survives case-insensitive channel lookup');

    my $ordinary = $mosaic->collect(
        channel => '#spark', generation => 71, nick => 'Alice',
        bot_nick => 'Mediabot', message => 'je continue la conversation',
    );
    $assert->is($ordinary->{reason}, 'not_contribution',
        'mb710-1011: ordinary conversation is never captured');
    $assert->is($ordinary->{count}, 0,
        'mb710-1011: ordinary conversation leaves the collector untouched');

    my $invalid = $mosaic->collect(
        channel => '#spark', generation => 71, nick => 'Alice',
        bot_nick => 'Mediabot', message => '+deux mots',
    );
    $assert->is($invalid->{reason}, 'invalid_word',
        'mb710-1011: a multi-word payload fails the explicit grammar');

    my $first = $mosaic->collect(
        channel => '#spark', generation => 71, nick => 'Alice',
        bot_nick => 'Mediabot', message => "\x02+hibou\x0f",
    );
    $assert->is($first->{count}, 1,
        'mb710-1011: one formatted +word becomes one clean contribution');
    $assert->is($first->{ready}, 0,
        'mb710-1011: one voice cannot fabricate a collective payoff');

    my $duplicate = $mosaic->collect(
        channel => '#spark', generation => 71, nick => 'ALICE',
        bot_nick => 'Mediabot', message => '+dragon',
    );
    $assert->is($duplicate->{reason}, 'duplicate_nick',
        'mb710-1011: one nick cannot occupy multiple voice slots');

    my $second = $mosaic->collect(
        channel => '#spark', generation => 71, nick => 'Bob',
        bot_nick => 'Mediabot', message => "+théière",
    );
    $assert->is($second->{reason}, 'target_reached',
        'mb710-1011: the audience-sized target closes deterministically');
    $assert->is($second->{ready}, 1,
        'mb710-1011: readiness is explicit metadata');

    my $items = $mosaic->contributions(
        channel => '#spark', generation => 71,
    );
    $assert->is(join(',', @$items), 'hibou,théière',
        'mb710-1011: provider boundary receives only the bounded words');
    $assert->unlike(join(',', @$items), qr/Alice|Bob/i,
        'mb710-1011: contributor identities never enter the provider payload');

    my $closing = $mosaic->mark_closing(
        channel => '#spark', generation => 71,
    );
    $assert->is($closing->{action}, 'close',
        'mb710-1011: completed set freezes before synthesis');
    my $late = $mosaic->collect(
        channel => '#spark', generation => 71, nick => 'Carol',
        bot_nick => 'Mediabot', message => '+cape',
    );
    $assert->is($late->{reason}, 'closing',
        'mb710-1011: late input cannot mutate an in-flight synthesis');

    my $log = Mediabot::Spark::Mosaic::format_mosaic_log('#spark', $second);
    $assert->like($log, qr/^\[SPARK_MOSAIC\].*count=2.*target=2/,
        'mb710-1011: lifecycle diagnostics expose bounded metadata');
    $assert->unlike($log, qr/hibou|théière|Alice|Bob/i,
        'mb710-1011: lifecycle diagnostics expose neither words nor nicks');

    $now += 30;
    $assert->is($mosaic->snapshot('#spark')->{closing_timed_out}, 1,
        'mb710-1011: stuck synthesis has a bounded timeout');
    $assert->is($mosaic->forget_channel('#spark'), 1,
        'mb710-1011: cleanup destroys all ephemeral Mosaic material');
};
