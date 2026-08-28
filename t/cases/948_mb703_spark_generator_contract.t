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

    $assert->like($fork->{system}, qr/Never pit two channel participants against each other/i,
        'mb708: Fork prompt forbids lazy person-versus-person framing');
    $assert->like($fork->{system}, qr/avoid the lazy pattern "who is right\?"/i,
        'mb708: Fork prompt explicitly rejects the observed who-is-right pattern');

    my $reaction_req = build_spark_request(
        kind => 'reaction', language => 'fr', provider => 'auto',
        context => [
            'Alice: encore un test rapide',
            'Bob: tu avais dit ça il y a vingt minutes',
            'Alice: techniquement il est toujours rapide',
        ],
    );
    $assert->is($reaction_req->{purpose}, 'spark.reaction',
        'mb708: Reaction owns a provider-neutral Spark purpose');
    $assert->like($reaction_req->{system}, qr/Do not ask a question, do not offer A\/B choices/i,
        'mb708: Reaction is deliberately conversational rather than a quiz');

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

    my $reaction = parse_spark_generation(
        'reaction',
        'LINE: Troisième "test rapide" : le mot rapide porte désormais une cape d\'invisibilité.',
    );
    $assert->is($reaction->{action}, 'ready',
        'mb708: compact Reaction line is accepted');
    my $reaction_declined = parse_spark_generation('reaction', 'NO_SPARK');
    $assert->is($reaction_declined->{reason}, 'model_declined',
        'mb708: Reaction may decline when recent context has no precise hook');

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
