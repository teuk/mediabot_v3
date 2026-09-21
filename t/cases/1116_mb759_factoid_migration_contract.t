# MB759 — package, machine contract and operator guide freeze read adoption.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use JSON::PP ();

sub slurp_1116 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    require Mediabot::Plugin::ManifestV3;

    my $contract = JSON::PP->new->decode(
        slurp_1116('plugins/API_V3_CONTRACT.json'));
    $assert->is($contract->{milestone}, 'MB761',
        'machine contract records the factoid adoption milestone');
    $assert->is($contract->{factoid_read_limits}{plugin_adoption},
        'factoids-v3 factoid, factoids, learn and forget, inactive by default',
        'machine contract keeps factoid adoption operator-controlled');
    $assert->is(join(',',
        @{ $contract->{factoid_read_migration}{commands} }),
        'factoid,factoids',
        'machine contract names only the pure read migrations');
    $assert->is(join(',',
        @{ $contract->{factoid_read_migration}{excluded_commands} }),
        'whatis,?keyword',
        'machine contract still excludes recall-counter mutation paths');

    my $manifest = Mediabot::Plugin::ManifestV3->load_file(
        'plugins/factoids-v3/plugin.json', expected_name => 'factoids-v3');
    $assert->is($manifest->{version}, '1.1.0',
        'factoid adoption package records write-command expansion');
    for my $command (qw(factoid factoids)) {
        $assert->is($manifest->{commands}{$command}{migration},
            'legacy-public-fallback',
            "$command uses the reversible saved-handler bridge");
    }
    $assert->ok(!exists($manifest->{commands}{whatis}),
        'package manifest still cannot mount recall mutation');

    my $guide = slurp_1116('docs/FACTOID_COMMAND_V3_PILOT.md');
    $assert->like($guide,
        qr/`observe`.*historical handler.*only visible answer/s,
        'pilot guide freezes silent shadow semantics');
    $assert->like($guide,
        qr/`whatis` and `\?keyword` remain historical/,
        'pilot guide records the deliberately excluded recall commands');
    $assert->like($guide,
        qr/\.plugins policy factoids-v3 #test off/,
        'pilot guide gives one-step channel rollback');
};
