# t/cases/719_mb509_configure_drift_fail_closed.t
# =============================================================================
# mb509 — configure must detect drift and fail closed on unresolved DB state.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_719 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $configure = _slurp_719(File::Spec->catfile('.', 'configure'));
    my $tool      = _slurp_719(File::Spec->catfile('.', 'tools', 'check_schema_drift.pl'));
    my $cfgdoc    = _slurp_719(File::Spec->catfile('.', 'docs', 'CONFIGURE.md'));
    my $readme    = _slurp_719(File::Spec->catfile('.', 'README.md'));
    my $dbdoc     = _slurp_719(File::Spec->catfile('.', 'docs', 'DB_MIGRATIONS.md'));
    my $migread   = _slurp_719(File::Spec->catfile('.', 'install', 'migrations', 'README.md'));

    $assert->like($configure,
        qr/perl "\$DRIFT_TOOL" --conf "\$CONFIG_FILE" --strict --types --indexes\n\s*local rc=\$\?/,
        'initial configure drift check is strict, type-aware and index-aware');
    $assert->like($configure,
        qr/--generate-migration --types --indexes >"\$preview"/,
        'generated review plan includes type and index drift');
    $assert->like($configure,
        qr/perl "\$DRIFT_TOOL" --conf "\$CONFIG_FILE" --strict --types --indexes\n\s*else/,
        'post-migration configure check uses the complete strict mode');

    $assert->unlike($configure, qr/run_drift_workflow \|\| true/,
        'existing-install workflow no longer swallows drift-check failures');
    $assert->like($configure,
        qr/Database drift remains unresolved.*?return 1/s,
        'declining migrations leaves configure in a non-success state');

    $assert->like($tool,
        qr/SQL preview\s+:.*--generate-migration --types --indexes/,
        'drift-tool hint generates a complete type/index-aware report');

    for my $pair (
        [ 'README', $readme ],
        [ 'DB migration doc', $dbdoc ],
        [ 'migration README', $migread ],
    ) {
        my ($label, $text) = @$pair;
        $assert->like($text, qr/--generate-migration --types --indexes/,
            "$label documents complete migration-plan generation");
    }

    $assert->like($cfgdoc,
        qr/--strict --types --indexes/,
        'configure documentation matches full drift validation');
    $assert->like($cfgdoc,
        qr/exits\s+non-zero/i,
        'configure documentation states fail-closed behavior');
};
