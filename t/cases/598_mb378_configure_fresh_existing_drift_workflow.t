use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_mb378_config_flow {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $configure  = _slurp_mb378_config_flow(File::Spec->catfile('.', 'configure'));
    my $wizard     = _slurp_mb378_config_flow(File::Spec->catfile('.', 'install', 'configure.pl'));
    my $db_install = _slurp_mb378_config_flow(File::Spec->catfile('.', 'install', 'db_install.sh'));
    my $helper     = _slurp_mb378_config_flow(File::Spec->catfile('.', 'install', 'configure_config.pl'));
    my $sample     = _slurp_mb378_config_flow(File::Spec->catfile('.', 'mediabot.sample.conf'));

    $assert->like($configure, qr/INSTALL_MODE="fresh"/, 'orchestrator detects a fresh install');
    $assert->like($configure, qr/INSTALL_MODE="existing"/, 'orchestrator detects an existing install');
    $assert->like($configure, qr/sudo "\$INSTALL_DIR\/db_install\.sh" -c "\$CONFIG_FILE"/,
        'fresh path still creates/configures the database');
    $assert->like($configure, qr/check_schema_drift\.pl/,
        'existing path integrates the schema drift checker');
    $assert->like($configure, qr/--generate-migration/,
        'drift path creates a review-only migration preview');
    $assert->like($configure, qr/Generated SQL is never applied automatically/,
        'generated SQL is explicitly never auto-applied');
    $assert->like($configure, qr/db_migrate\.sh/,
        'official migrations can be selected explicitly');
    $assert->like($configure, qr/--backup-dir "\$CONFIG_DIR\/config-backups"/,
        'existing config path creates backups');
    $assert->like($configure, qr/PARTYLINE_EVAL_ENABLED=0/,
        'fresh path explicitly disables dangerous eval');
    $assert->unlike($configure, qr/PARTYLINE_EVAL_ENABLED=1/,
        'configure never offers or writes eval enabled');

    $assert->like($wizard, qr/write_overlay_and_merge/,
        'IRC wizard updates the config atomically');
    $assert->unlike($wizard, qr/open\s+CONF\s*,\s*["']>>/,
        'IRC wizard no longer appends duplicate INI sections');
    $assert->like($db_install, qr/configure_config\.pl/,
        'DB installer uses the atomic config engine');
    $assert->unlike($db_install, qr/cat\s+>>"\$CONFIG_FILE"/,
        'DB installer no longer appends a second mysql section');

    $assert->like($helper, qr/Existing\/custom settings preserved by \.\/configure/,
        'merge engine preserves custom settings');
    $assert->like($helper, qr/rename \$tmp, \$config/,
        'merge engine uses atomic replacement');
    $assert->like($helper, qr/Duplicate active keys normalized/,
        'merge engine reports normalization of duplicate keys');

    $assert->like($sample, qr/^MAIN_PROG_DBPASS=$/m, 'sample DB password default is empty');
    $assert->like($sample, qr/^UNET_CSERVICE_PASSWORD=$/m, 'sample service password default is empty');
    $assert->like($sample, qr/^YOUTUBE_APIKEY=$/m, 'sample YouTube API key default is empty');
    $assert->like($sample, qr/^MAIN_PROG_DEBUG=0$/m, 'sample debug default is production-safe');
};
