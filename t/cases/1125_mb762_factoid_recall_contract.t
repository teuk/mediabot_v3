# MB762 — machine, source and documentation contracts expose authority only.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use JSON::PP ();

sub slurp_1125 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    my $contract = JSON::PP->new->decode(
        slurp_1125('plugins/API_V3_CONTRACT.json'));
    $assert->is($contract->{milestone}, 'MB784',
        'machine contract records recall authority');
    $assert->is(join(',',
        @{ $contract->{factoid_write_limits}{operations} }),
        'upsert,delete,recall',
        'factoid writes expose exactly three reviewed operations');
    $assert->is($contract->{factoid_recall_authority}{activation},
        'on only', 'recall mutation is never available in observe');
    $assert->is($contract->{factoid_recall_authority}{command_adoption},
        'whatis in MB763; the existing ?keyword parser route enters the same mounted handler',
        'recall authority now records its reviewed command adoption');

    my $context = slurp_1125('Mediabot/PluginContext.pm');
    my $manager = slurp_1125('Mediabot/PluginManager.pm');
    my $service = slurp_1125(
        'Mediabot/Plugin/FactoidWriteServiceV3.pm');
    $assert->like($context, qr/sub factoid_recall\b/,
        'PluginContext exposes one named recall method');
    $assert->like($manager, qr/recall\s*=>\s*'recall'/,
        'manager allowlist recognizes the exact recall operation');
    $assert->like($service,
        qr/WHERE c\.name = \? AND f\.keyword = \?/,
        'service binds recall to channel and normalized keyword');
    $assert->unlike($service, qr/SET\s+f\.hits\s*=\s*\?/,
        'plugin cannot submit an arbitrary counter value');

    my $manifest = JSON::PP->new->decode(
        slurp_1125('plugins/factoids-v3/plugin.json'));
    $assert->ok(exists($manifest->{commands}{whatis}),
        'whatis is adopted after the authority-only milestone');
    $assert->is(scalar keys %{ $manifest->{commands} }, 5,
        'package command surface grows by exactly one command');

    my $api = slurp_1125('docs/PLUGIN_API_V3.md');
    my $architecture = slurp_1125('docs/PLUGIN_ARCHITECTURE.md');
    $assert->like($api,
        qr/MB762 adds the\s+distinct recall-counter authority\. MB763\s+mounts `whatis`/s,
        'author guide separates authority from later adoption');
    $assert->like($architecture,
        qr/MB762 — factoid recall-counter authority/,
        'roadmap names the bounded authority milestone');
};
