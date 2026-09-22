# MB761 — package, machine contract and guides freeze write-command adoption.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use JSON::PP ();

sub slurp_1122 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    require Mediabot::Plugin::ManifestV3;

    my $contract = JSON::PP->new->decode(
        slurp_1122('plugins/API_V3_CONTRACT.json'));
    $assert->is($contract->{milestone}, 'MB763',
        'machine contract advances beyond write-command adoption');
    $assert->is($contract->{factoid_write_limits}{plugin_adoption},
        'factoids-v3 learn, forget and whatis recall accounting, inactive by default',
        'write adoption remains operator-controlled');
    $assert->is(join(',',
        @{ $contract->{factoid_write_migration}{commands} }),
        'learn,forget,whatis',
        'machine contract names all adopted factoid write paths');
    $assert->is(join(',',
        @{ $contract->{factoid_write_migration}{excluded_commands} }),
        '',
        'no factoid write command remains excluded');
    $assert->is($contract->{factoid_write_migration}{observe_mutations},
        'v3 suppressed; historical fallback remains authoritative',
        'observe cannot double-write factoid state');

    my $manifest = Mediabot::Plugin::ManifestV3->load_file(
        'plugins/factoids-v3/plugin.json', expected_name => 'factoids-v3');
    $assert->is($manifest->{version}, '1.2.0',
        'factoid package version advances for recall adoption');
    $assert->is(join(',', @{ $manifest->{capabilities} }),
        'data.factoids.read,data.factoids.write,irc.reply,irc.notice',
        'package requests only factoid data and bounded IRC capabilities');
    for my $command (qw(factoid factoids learn forget whatis)) {
        $assert->is($manifest->{commands}{$command}{migration},
            'legacy-public-fallback',
            "$command uses the reversible saved-handler bridge");
    }
    $assert->ok(exists($manifest->{commands}{whatis}),
        'package mounts recall after the separate authority gate');

    my $source = slurp_1122('plugins/factoids-v3/lib/Factoids.pm');
    $assert->like($source, qr/factoid_upsert\(/,
        'learn delegates to the bounded write facade');
    $assert->like($source, qr/factoid_delete\(/,
        'forget delegates to the authorized delete facade');
    $assert->unlike($source,
        qr/\b(?:DBI|prepare|execute|INSERT|UPDATE|DELETE)\b/,
        'package source exposes no SQL or database primitive');

    my $guide = slurp_1122('docs/FACTOID_COMMAND_V3_PILOT.md');
    $assert->like($guide,
        qr/`observe`.*suppresses the v3 write\s+before the service/s,
        'pilot guide freezes non-duplicating shadow writes');
    $assert->like($guide,
        qr/successful on recalls increment once/,
        'pilot guide preserves one-counter recall semantics');
    $assert->like($guide,
        qr/disposable.*factoid.*deleted/s,
        'pilot requires cleanup of live mutation evidence');
};
