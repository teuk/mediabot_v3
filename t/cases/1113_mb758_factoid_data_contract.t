# MB758 — machine contract and documentation freeze the factoid read boundary.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use JSON::PP ();

sub slurp_1113 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

return sub {
    my ($assert) = @_;
    my $contract = JSON::PP->new->decode(
        slurp_1113('plugins/API_V3_CONTRACT.json'));
    $assert->is($contract->{milestone}, 'MB767',
        'machine contract records the current factoid platform milestone');
    $assert->ok(grep($_ eq 'data.factoids.read',
        @{ $contract->{implemented_capabilities} }),
        'machine contract implements the exact factoid read capability');
    $assert->is(join(',',
        @{ $contract->{factoid_read_limits}{operations} }),
        'by_keyword,list,top',
        'machine contract freezes the three approved operations');
    $assert->is($contract->{factoid_read_limits}{maximum_list_results}, 60,
        'machine contract publishes the historical list ceiling');
    $assert->is($contract->{factoid_read_limits}{maximum_top_results}, 10,
        'machine contract publishes the top ranking ceiling');
    $assert->is($contract->{factoid_read_limits}{channel_source},
        'invocation policy',
        'machine contract makes channel authority explicit');
    $assert->is($contract->{factoid_read_limits}{recall_counter_writes},
        'separate data.factoids.write authority',
        'read capability cannot alter recall accounting by itself');
    $assert->is($contract->{factoid_read_limits}{plugin_adoption},
        'factoids-v3 factoid, factoids, learn, forget and whatis plus the existing ?keyword route, inactive by default',
        'read authority now has an inert operator-controlled package');
    $assert->ok(grep($_ eq 'Mediabot::Plugin::FactoidRecordV3',
        @{ $contract->{plugin_receives} }),
        'machine contract names the detached factoid record');

    my $context = slurp_1113('Mediabot/PluginContext.pm');
    my $runtime = slurp_1113('Mediabot/Plugin/RuntimeV3.pm');
    my $manager = slurp_1113('Mediabot/PluginManager.pm');
    my $service = slurp_1113('Mediabot/Plugin/FactoidServiceV3.pm');
    $assert->like($context,
        qr/require_capability\('data\.factoids\.read'\)/,
        'context checks the exact capability before every call');
    $assert->like($runtime, qr/factoids_read_sink/,
        'runtime wires only the bounded factoid sink');
    $assert->like($manager,
        qr/by_keyword\s*=>\s*'by_keyword'.*list\s*=>\s*'list'.*top\s*=>\s*'top'/s,
        'manager allowlists the three factoid operations');
    $assert->ok($service !~ /\b(?:INSERT|UPDATE|DELETE)\b/i,
        'factoid read service source contains no mutating SQL verb');
    $assert->ok(-f 'plugins/factoids-v3/plugin.json',
        'factoid adoption package is present without weakening the facade');

    my $guide = slurp_1113('docs/PLUGIN_API_V3.md');
    $assert->like($guide,
        qr/They never increment\s+the recall counter/,
        'author guide records the side-effect-free read guarantee');
    $assert->like($guide,
        qr/MB759 adds the inert `factoids-v3` package/,
        'author guide records the separately reviewed adoption boundary');
};
