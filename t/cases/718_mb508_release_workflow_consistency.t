# t/cases/718_mb508_release_workflow_consistency.t
# =============================================================================
# mb508 — release workflow consistency after index-aware drift support.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_718 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $configure = _slurp_718(File::Spec->catfile('.', 'configure'));
    my $tool      = _slurp_718(File::Spec->catfile('.', 'tools', 'check_schema_drift.pl'));
    my $readme    = _slurp_718(File::Spec->catfile('.', 'README.md'));
    my $dbdoc     = _slurp_718(File::Spec->catfile('.', 'docs', 'DB_MIGRATIONS.md'));
    my $migread   = _slurp_718(File::Spec->catfile('.', 'install', 'migrations', 'README.md'));
    my $changelog = _slurp_718(File::Spec->catfile('.', 'CHANGELOG.md'));

    $assert->like($configure,
        qr/perl "\$DRIFT_TOOL" --conf "\$CONFIG_FILE" --strict --types --indexes/,
        'configure initial drift check includes required indexes');
    $assert->like($configure,
        qr/--generate-migration --types --indexes >"\$preview"/,
        'configure preview includes missing indexes');
    $assert->like($configure,
        qr/--strict --types --indexes/,
        'configure post-migration strict check includes indexes');

    $assert->like($configure, qr/\(\[0-9\]\{8\}\)/,
        'configure extracts an embedded YYYYMMDD migration date');
    $assert->like($configure, qr/sort -k1,1 -k2,2/,
        'configure sorts migrations by date key then filename');
    $assert->unlike($configure,
        qr/-printf '%f\\n' \| sort\)/,
        'configure no longer uses misleading plain lexical order');

    $assert->like($tool,
        qr/--generate-migration\s+Print reviewable SQL for missing tables\/columns\/indexes\/reference rows/,
        'drift tool help documents generated index/reference SQL');

    for my $pair (
        [ 'README', $readme ],
        [ 'DB migration doc', $dbdoc ],
        [ 'migration README', $migread ],
    ) {
        my ($label, $text) = @$pair;
        $assert->unlike($text, qr/does not compare indexes/i,
            "$label has no obsolete index limitation");
        $assert->like($text, qr/--indexes/,
            "$label documents index-aware drift checks");
    }

    for my $cmd (qw(tell learn whatis factoids factoid convert)) {
        $assert->like($changelog, qr/\b\Q$cmd\E\b/,
            "CHANGELOG documents notable command: $cmd");
    }
    $assert->like($changelog, qr/install\/migrations\/README\.md/,
        'CHANGELOG points to authoritative migration order');

    # mb509: the "Next check" hint printed by configure must match the workflow
    # it actually runs (index-aware), not a weaker command.
    $assert->like($configure,
        qr/Next check\s*:.*--strict --types --indexes/,
        'configure Next-check hint is index-aware (matches the workflow)');

    # mb509: --help must not require DBI at load time (works on a fresh checkout
    # before CPAN modules are installed). DBI is loaded lazily, not via `use`.
    $assert->unlike($tool, qr/^use DBI;/m,
        'check_schema_drift does not hard-require DBI at compile time');
    $assert->like($tool, qr/require DBI/,
        'check_schema_drift loads DBI lazily (after --help short-circuit)');
};
