use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use Mediabot::Spark::Event qw(spark_event_profile);
use Mediabot::Spark::Generator qw(
    build_spark_request parse_spark_generation
    spark_generation_summary spark_request_summary
);

return sub {
    my ($assert) = @_;

    my @context = (
        'Alice: le café a encore gagné',
        'Bob: le test devait durer deux minutes',
        'Carol: il demande maintenant un avocat',
    );
    my $request = build_spark_request(
        kind => 'stage_cue', language => 'fr', provider => 'auto',
        context => \@context,
    );
    $assert->is($request->{purpose}, 'spark.stage_cue',
        'mb709-999: Stage Cue owns a provider-neutral purpose');
    $assert->like($request->{system}, qr/The bot is the only actor/i,
        'mb709-999: only Mediabot may act in the generated cue');
    $assert->like($request->{system}, qr/Do not name, address, quote, rank/i,
        'mb709-999: prompt forbids participant targeting and ranking');
    $assert->like($request->{system}, qr/never include \/me, ACTION, CTCP markers/i,
        'mb709-999: provider must return an unframed action body');
    $assert->is(spark_request_summary($request)->{purpose}, 'spark.stage_cue',
        'mb709-999: request summary recognizes the action purpose');

    my $profile = spark_event_profile('stage_cue');
    $assert->is($profile->{delivery_style}, 'action',
        'mb709-999: event catalog declares IRC action delivery');
    $assert->ok(!$profile->{requires_response},
        'mb709-999: Stage Cue never invents a participation contract');

    my $ready = parse_spark_generation(
        'stage_cue',
        'LINE: déplie un minuscule tapis rouge pour le café victorieux.',
    );
    $assert->is($ready->{action}, 'ready',
        'mb709-999: one safe action body is accepted');
    $assert->is(spark_generation_summary($ready)->{content_fields}, 1,
        'mb709-999: logs retain content shape only');
    $assert->is(parse_spark_generation('stage_cue', 'NO_SPARK')->{reason},
        'model_declined',
        'mb709-999: weak context can be declined explicitly');

    for my $wire (
        'LINE: /me waves',
        'LINE: ACTION waves',
        'LINE: PRIVMSG #elsewhere :waves',
        "LINE: waves\x01ACTION injected\x01",
        "LINE: waves\nNOTICE #elsewhere :injected",
    ) {
        $assert->is(
            parse_spark_generation('stage_cue', $wire)->{action},
            'no_content',
            'mb709-999: framing and protocol-shaped output fail closed',
        );
    }
};
