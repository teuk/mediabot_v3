# MB742 — strict API v3 manifest and side-effect-free package discovery.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use JSON::PP ();

sub _slurp_1066 {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    require Mediabot::Plugin::ManifestV3;
    require Mediabot::Plugin::RuntimeV3;

    my $contract = JSON::PP->new->decode(
        _slurp_1066('plugins/API_V3_CONTRACT.json'));
    $assert->is($contract->{api}, 3, 'MB742 publishes API v3 contract');
    $assert->is($contract->{status}, 'experimental',
        'MB742 labels API v3 experimental');
    $assert->is($contract->{activation_default}, 'off',
        'API v3 packages default to off');
    $assert->is($contract->{manifest_max_bytes},
        $Mediabot::Plugin::ManifestV3::MAX_MANIFEST_BYTES,
        'machine contract matches manifest byte bound');

    my $manifest = Mediabot::Plugin::ManifestV3->load_file(
        'plugins/hello-v3/plugin.json', expected_name => 'hello-v3');
    $assert->is($manifest->{api}, 3, 'witness manifest validates as API v3');
    $assert->is($manifest->{activation}{default}, 'off',
        'witness is inert by default');
    $assert->is(join(',', @{ $manifest->{capabilities} }),
        'events.subscribe,irc.reply,scheduler.jobs',
        'witness requests only its three bounded capabilities');
    $assert->is($manifest->{commands}{v3hello}{handler}, 'command_hello',
        'witness command names its explicit handler');
    $assert->is($manifest->{events}[0]{name}, 'scheduler.minute',
        'witness declares one versioned event');
    $assert->is($manifest->{jobs}{heartbeat}{interval_seconds}, 300,
        'witness declares one bounded shared job');

    my $fake_manager = bless {}, 'T1066::Manager';
    my $runtime = Mediabot::Plugin::RuntimeV3->new(
        manager => $fake_manager, plugin_dir => 'plugins');
    my @packages = $runtime->discover_packages;
    my @witness = grep { $_->{name} eq 'hello-v3' } @packages;
    $assert->is(scalar @witness, 1,
        'discovery finds the direct-child witness package');
    $assert->is($witness[0]{activation}, 'off',
        'discovery exposes activation without executing entrypoint');
    $assert->ok(!'Mediabot::Plugin::V3::Hello'->can('new'),
        'discovery does not load plugin Perl code');

    my @factoids = grep { $_->{name} eq 'factoids-v3' } @packages;
    $assert->is(scalar @factoids, 1,
        'discovery finds the inert factoid adoption package');
    $assert->is($factoids[0]{activation}, 'off',
        'factoid package discovery preserves default-off activation');
    $assert->is(join(',', @{ $factoids[0]{capabilities} }),
        'data.factoids.read,irc.notice',
        'discovery exposes only the two factoid package capabilities');
    $assert->ok(!'Mediabot::Plugin::Factoids'->can('new'),
        'factoid discovery does not execute its entrypoint');

    my %unknown = (%$manifest, surprise => 1);
    my $ok = eval { Mediabot::Plugin::ManifestV3->validate(\%unknown); 1 };
    $assert->like($@ // '', qr/unknown manifest field 'surprise'/,
        'unknown manifest fields fail closed');

    my %on = (%$manifest, activation => { default => 'on' });
    $ok = eval { Mediabot::Plugin::ManifestV3->validate(\%on); 1 };
    $assert->like($@ // '', qr/default must be 'off'/,
        'automatic activation is rejected in MB742');

    my %traversal = (%$manifest,
        runtime => { %{ $manifest->{runtime} }, entrypoint => '../Oops.pm' });
    $ok = eval { Mediabot::Plugin::ManifestV3->validate(\%traversal); 1 };
    $assert->like($@ // '', qr/relative \.pm path/,
        'entrypoint traversal fails closed');

    my %bad_grant = (%$manifest,
        capabilities => ['root.everything']);
    $ok = eval { Mediabot::Plugin::ManifestV3->validate(\%bad_grant); 1 };
    $assert->like($@ // '', qr/unknown capability/,
        'undeclared capability vocabulary fails closed');
};
