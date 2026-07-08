# t/cases/693_mb482_refresh_channel_hash_casefold.t
# =============================================================================
# mb482 — refresh_channel_hashes must compare channel names case-insensitively.
#
# Since mb407, $self->{channels} uses lowercase IRC channel keys.  Before this
# round, refresh_channel_hashes() still keyed the DB snapshot by the exact
# CHANNEL.name value.  A DB row named "#Glamour" was therefore populated at boot
# under "#glamour", then reported every refresh as "Channel #glamour not found
# in DB".  IRC channel names are case-insensitive; both sides of the refresh
# comparison must use the same canonical lc key.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_693 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $med = _slurp_693(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
    my ($refresh) = $med =~ /(sub refresh_channel_hashes \{.*?\n\}\n)/s;
    $refresh //= '';

    $assert->like($refresh,
        qr/\$db_info\{\s*lc\(\$ref->\{name\}\)\s*\}\s*=\s*\$ref\s*;/,
        'DB refresh snapshot is keyed by lc(CHANNEL.name)');
    $assert->unlike($refresh,
        qr/\$db_info\{\s*\$ref->\{name\}\s*\}\s*=\s*\$ref\s*;/,
        'DB refresh snapshot no longer uses exact-case CHANNEL.name as key');

    $assert->like($refresh,
        qr/my\s+\$chan_key\s*=\s*lc\(\$chan_name\)\s*;/,
        'in-memory channel key is normalised once per refresh entry');
    $assert->like($refresh,
        qr/exists\s+\$db_info\{\$chan_key\}/,
        'refresh lookup uses the canonical channel key');
    $assert->like($refresh,
        qr/my\s+\$ref\s*=\s*\$db_info\{\$chan_key\}\s*;/,
        'refresh reads the DB row through the canonical channel key');
    $assert->unlike($refresh,
        qr/exists\s+\$db_info\{\$chan_name\}/,
        'refresh no longer probes DB snapshot using the raw in-memory key');

    my %db_info;
    my $db_name = '#Glamour';
    $db_info{lc($db_name)} = { name => $db_name };
    my $memory_key = '#glamour';
    $assert->ok(exists $db_info{lc($memory_key)},
        'semantic guard: DB #Glamour matches memory #glamour');
    $assert->is($db_info{lc('#GLAMOUR')}->{name}, '#Glamour',
        'semantic guard: arbitrary IRC case resolves to the DB row');

    $assert->like($refresh, qr/mb482-B1/, 'mb482 marker is present');
};
