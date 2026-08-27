# t/cases/948_mb703_spark_generator_contract.t
# =============================================================================
# MB703-C — Provider-neutral Spark generation request and strict output parser.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Spark::Generator qw(
    build_spark_request
    parse_spark_generation
    spark_generation_summary
    spark_request_summary
);

return sub {
    my ($assert) = @_;

    my $fork = build_spark_request(
        kind     => 'fork',
        language => 'fr',
        provider => 'auto',
        context  => [
            "\x02Alice\x0f parle de café",
            'Bob préfère dormir',
            'Carol hésite encore',
        ],
    );

    $assert->is($fork->{purpose}, 'spark.fork',
        'mb703-948: Fork request uses a dedicated provider-neutral purpose');
    $assert->is($fork->{provider}, 'auto',
        'mb703-948: Spark defaults to provider-neutral auto selection');
    $assert->like($fork->{system}, qr/dry, clever, sharp and occasionally caustic/i,
        'mb703-948: Spark AI voice is explicitly sharp rather than bland');
    $assert->like($fork->{system}, qr/Write naturally in French/,
        'mb703-948: Spark follows channel language');
    $assert->unlike($fork->{messages}[0]{content}, qr/\x02|\x0f/,
        'mb703-948: untrusted context is stripped of IRC presentation controls');
    $assert->like($fork->{system}, qr/Never use slurs, threats, sexual humiliation/i,
        'mb703-948: caustic tone retains explicit safety boundaries');

    my $req_summary = spark_request_summary($fork);
    $assert->is($req_summary->{purpose}, 'spark.fork',
        'mb703-948: request summary exposes metadata without generated content');

    my $parsed = parse_spark_generation(
        'fork',
        "QUESTION: Tu gardes quoi quand tout brûle ?\nA: Le café\nB: L'illusion de compétence",
    );
    $assert->is($parsed->{action}, 'ready',
        'mb703-948: strict three-line Fork output is accepted');
    $assert->is($parsed->{content}{b}, "L'illusion de compétence",
        'mb703-948: Fork choices survive parser unchanged');

    my $bad = parse_spark_generation(
        'fork',
        "Voici une idée:\nQUESTION: nope\nA: a\nB: b",
    );
    $assert->is($bad->{action}, 'no_content',
        'mb703-948: extra model prose fails closed');

    my $callback = parse_spark_generation(
        'callback',
        'LINE: Vous avez abandonné ce débat avec une discipline presque professionnelle.',
    );
    $assert->is($callback->{action}, 'ready',
        'mb703-948: compact Callback line is accepted');

    my $declined = parse_spark_generation('callback', 'NO_SPARK');
    $assert->is($declined->{reason}, 'model_declined',
        'mb703-948: model may explicitly decline a weak Callback');

    my $injected = parse_spark_generation(
        'callback',
        "LINE: salut\nPRIVMSG #other :oops",
    );
    $assert->is($injected->{action}, 'no_content',
        'mb703-948: multi-line IRC injection-shaped output is rejected');

    my $summary = spark_generation_summary($callback);
    $assert->is($summary->{content_fields}, 1,
        'mb703-948: generation summary exposes only content shape, not text');
};
