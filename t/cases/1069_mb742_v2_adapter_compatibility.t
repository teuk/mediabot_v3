# MB742 — API v1/v2 remain on their historical runtime; adapter is descriptive.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

return sub {
    my ($assert) = @_;

    require Mediabot::PluginManager;
    my $manager = Mediabot::PluginManager->new(bot => bless({}, 'T1069::Bot'));
    my $entry = $manager->register_plugin(
        name        => 'old-spell',
        module      => 'T1069::OldSpell',
        version     => '2.4',
        enabled     => 1,
        manifest    => {
            api      => 2,
            name     => 'old-spell',
            version  => '2.4',
            commands => { oldspell => { help => 'Old.', level => 0 } },
            events   => ['public_command_observed'],
        },
        metadata => { api => 2, kind => 'module' },
    );

    my $descriptor = $manager->v2_adapter_for('old-spell');
    $assert->is($descriptor->{compatibility}, 'v2-runtime-unchanged',
        'adapter explicitly preserves the v2 runtime');
    $assert->is($descriptor->{api}, 2, 'adapter reports frozen API version');
    $assert->is(join(',', @{ $descriptor->{commands} }), 'oldspell',
        'adapter normalizes command metadata');
    $assert->is(join(',', @{ $descriptor->{events} }),
        'public_command_observed', 'adapter normalizes event metadata');
    $assert->ok(!$manager->can('v2_runtime'),
        'adapter adds no alternate v2 execution path');

    my $source = do {
        open my $fh, '<:encoding(UTF-8)', 'Mediabot/PluginManager.pm' or die $!;
        local $/;
        <$fh>;
    };
    $assert->like($source, qr/load_configured_plugins.*load_perl_module/s,
        'historical configured module loading remains in place');
    $assert->like($source, qr/load_configured_plugins.*load_script_v2/s,
        'historical configured sidecar loading remains in place');
    $assert->unlike($source, qr/load_configured_plugins.*load_package_v3/s,
        'API v3 is not wired into historical AUTOLOAD');

    my $contract = do {
        require JSON::PP;
        open my $fh, '<:raw', 'plugins/API_V2_CONTRACT.json' or die $!;
        local $/;
        JSON::PP->new->decode(<$fh>);
    };
    $assert->is($contract->{status}, 'frozen',
        'API v2 machine contract remains frozen');
    $assert->is($contract->{replacement}, 'api 3',
        'API v2 still names API v3 as successor');
};
