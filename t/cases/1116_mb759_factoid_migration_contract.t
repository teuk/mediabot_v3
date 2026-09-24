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
    $assert->is($contract->{milestone}, 'MB781',
        'machine contract records the factoid adoption milestone');
    $assert->is($contract->{factoid_read_limits}{plugin_adoption},
        'factoids-v3 factoid, factoids, learn, forget and whatis plus the existing ?keyword route, inactive by default',
        'machine contract keeps factoid adoption operator-controlled');
    $assert->is(join(',',
        @{ $contract->{factoid_read_migration}{commands} }),
        'factoid,factoids,whatis',
        'machine contract names the adopted factoid read paths');
    $assert->is(join(',',
        @{ $contract->{factoid_read_migration}{excluded_commands} }),
        '',
        'machine contract has no remaining excluded factoid read command');

    my $manifest = Mediabot::Plugin::ManifestV3->load_file(
        'plugins/factoids-v3/plugin.json', expected_name => 'factoids-v3');
    $assert->is($manifest->{version}, '1.2.0',
        'factoid adoption package records recall-command expansion');
    for my $command (qw(factoid factoids whatis)) {
        $assert->is($manifest->{commands}{$command}{migration},
            'legacy-public-fallback',
            "$command uses the reversible saved-handler bridge");
    }
    $assert->ok(exists($manifest->{commands}{whatis}),
        'package manifest mounts recall only after authority exists');

    my $guide = slurp_1116('docs/FACTOID_COMMAND_V3_PILOT.md');
    $assert->like($guide,
        qr/`observe`.*historical handler.*only visible answer/s,
        'pilot guide freezes silent shadow semantics');
    $assert->like($guide,
        qr/missing\s+`\?keyword` shortcuts remain silent/,
        'pilot guide records quiet shortcut parity');
    $assert->like($guide,
        qr/\.plugins policy factoids-v3 #test off/,
        'pilot guide gives one-step channel rollback');
};
