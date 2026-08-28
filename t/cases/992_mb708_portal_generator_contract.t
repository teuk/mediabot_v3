# t/cases/992_mb708_portal_generator_contract.t
use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Spark::Generator qw(
    build_spark_request
    parse_spark_generation
    spark_request_summary
);

return sub {
    my ($assert) = @_;

    my $open = build_spark_request(
        kind => 'portal', language => 'fr', provider => 'auto',
    );
    $assert->is($open->{purpose}, 'spark.portal',
        'mb708-992: Portal keeps one provider-neutral purpose');
    $assert->like($open->{system}, qr/Open a collaborative three-contribution Portal/i,
        'mb708-992: opening generation explicitly creates a three-input Portal');
    $assert->like($open->{system}, qr/three different people.*one short ingredient/is,
        'mb708-992: opener requests one contribution from each distinct human');
    $assert->like($open->{system}, qr/do not .*pretend.*already complete/is,
        'mb708-992: opener is explicitly forbidden from fabricating completion');

    my $close = build_spark_request(
        kind => 'portal', language => 'fr', provider => 'auto',
        contributions => [
            "\x02une théière syndiquée\x0f",
            'un dragon comptable',
            'un formulaire en feu',
        ],
    );
    $assert->like($close->{system}, qr/Close a collaborative Portal/i,
        'mb708-992: contribution payload selects the closing contract');
    $assert->like($close->{system}, qr/do not name or rank their authors/i,
        'mb708-992: closing prompt forbids contributor profiling');
    $assert->like($close->{system}, qr/Do not ask another question/i,
        'mb708-992: payoff cannot silently reopen the event');
    $assert->like($close->{messages}[0]{content}, qr/une théière syndiquée.*un dragon comptable.*un formulaire en feu/is,
        'mb708-992: closing request receives every bounded contribution');
    $assert->unlike($close->{messages}[0]{content}, qr/[\x02\x0f]/,
        'mb708-992: contribution controls are removed before the provider boundary');

    my $too_few_ok = eval {
        build_spark_request(
            kind => 'portal', language => 'fr',
            contributions => [ 'une seule idée' ],
        );
        1;
    };
    $assert->ok(!$too_few_ok,
        'mb708-992: Portal synthesis refuses fewer than two contributions');

    my $parsed = parse_spark_generation(
        'portal',
        'LINE: La théière syndiquée réclame le dragon au service comptabilité.',
    );
    $assert->is($parsed->{action}, 'ready',
        'mb708-992: one-line Portal payoff remains IRC-renderable');

    my $summary = spark_request_summary($close);
    $assert->is($summary->{purpose}, 'spark.portal',
        'mb708-992: Portal request summary exposes metadata only');
    $assert->unlike(join(' ', values %$summary), qr/théière|dragon|formulaire/i,
        'mb708-992: request summary never exposes contribution content');
};
