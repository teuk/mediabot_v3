# t/cases/957_mb703_spark_generator_provider_metadata.t
# =============================================================================
# MB703-E — Generator preserves bounded provider diagnostics, never credentials.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Spark::Generator qw(spark_generation_summary);

{
    package MB703E::Client;
    sub new { bless {}, shift }
    sub execute {
        return {
            ok => 1,
            answer => 'LINE: Même le silence a demandé une mutation ailleurs.',
            provider => 'openai',
            model => 'gpt-test',
            provider_fallback => 1,
            model_fallback => 0,
        };
    }
    sub submit {
        my ($self, $request, %args) = @_;
        $args{on_done}->({
            ok => 1,
            answer => "QUESTION: On appelle ça comment ?\nA: Une architecture\nB: Un accident documenté",
            provider => 'anthropic',
            model => 'claude-test',
            provider_fallback => 0,
            model_fallback => 1,
        });
        return 1;
    }
}

return sub {
    my ($assert) = @_;

    my $gen = Mediabot::Spark::Generator->new(client => MB703E::Client->new);
    my $sync = $gen->execute(
        kind => 'callback', language => 'fr', context => [ 'Alice: silence', 'Bob: remarquable', 'Carol: presque inquiétant' ],
    );
    $assert->is($sync->{provider}, 'openai',
        'mb703-957: sync generation preserves safe provider name');
    $assert->is($sync->{model}, 'gpt-test',
        'mb703-957: sync generation preserves safe model name');
    $assert->is($sync->{provider_fallback}, 1,
        'mb703-957: provider fallback metadata is preserved');

    my $sync_summary = spark_generation_summary($sync);
    $assert->is($sync_summary->{content_fields}, 1,
        'mb703-957: metadata summary exposes content shape only');
    $assert->is($sync_summary->{provider}, 'openai',
        'mb703-957: safe summary keeps provider metadata');

    my $async;
    my $started = $gen->submit(
        kind => 'fork', language => 'fr',
        on_done => sub { $async = shift },
    );
    $assert->is($started, 1,
        'mb703-957: async generation still delegates to common AI client');
    $assert->is($async->{provider}, 'anthropic',
        'mb703-957: async generation preserves provider metadata');
    $assert->is($async->{model_fallback}, 1,
        'mb703-957: async generation preserves model fallback metadata');

    my $summary = spark_generation_summary($async);
    $assert->is($summary->{provider}, 'anthropic',
        'mb703-957: async safe summary retains provider');
    $assert->is($summary->{model}, 'claude-test',
        'mb703-957: async safe summary retains model');
};
