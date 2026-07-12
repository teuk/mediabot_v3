# t/cases/716_mb506_release_consistency.t
# =============================================================================
# mb506 — release/fresh-install consistency guards.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_716 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $schema = _slurp_716(File::Spec->catfile('.', 'install', 'mediabot.sql'));
    my ($quotes) = $schema =~ /(CREATE TABLE `QUOTES` \(.*?\n\) ENGINE=InnoDB)/s;

    $assert->ok(defined $quotes && $quotes ne '', 'fresh schema QUOTES table found');
    $assert->like($quotes, qr/`hits`\s+BIGINT UNSIGNED NOT NULL DEFAULT 0/,
        'fresh schema includes QUOTES.hits');
    $assert->like($quotes,
        qr/KEY `idx_quotes_channel_hits` \(`id_channel`, `hits`\)/,
        'fresh schema includes idx_quotes_channel_hits');

    my $migration = _slurp_716(
        File::Spec->catfile('.', 'install', 'migrations', '20260710_quotes_hits.sql')
    );
    $assert->like($migration, qr/INDEX_NAME\s*=\s*'idx_quotes_channel_hits'/,
        'quotes migration checks the expected index');
    $assert->like($migration,
        qr/ADD INDEX `idx_quotes_channel_hits` \(`id_channel`, `hits`\)/,
        'quotes migration creates the same composite index');

    my $readme = _slurp_716(File::Spec->catfile('.', 'README.md'));
    $assert->like($readme,
        qr/check_schema_drift\.pl --conf=mediabot\.conf --generate-migration --types --indexes/,
        'README documents index-aware generate-migration');
    $assert->like($readme,
        qr/check_schema_drift\.pl --conf=mediabot\.conf --strict --types --indexes/,
        'README documents strict type and index validation');
    $assert->like($readme, qr/\[Changelog and 3\.3 release notes\]\(CHANGELOG\.md\)/,
        'README links to CHANGELOG.md');

    my $dbdoc = _slurp_716(File::Spec->catfile('.', 'docs', 'DB_MIGRATIONS.md'));
    $assert->like($dbdoc, qr/compares these indexes when `--indexes` is supplied/i,
        'DB migration documentation states index-aware validation');
    $assert->like($dbdoc, qr/SHOW INDEX FROM QUOTES\s+WHERE Key_name = 'idx_quotes_channel_hits'/,
        'DB migration documentation gives an explicit quote index check');

    my $migread = _slurp_716(
        File::Spec->catfile('.', 'install', 'migrations', 'README.md')
    );
    $assert->like($migread,
        qr/check_schema_drift\.pl --conf=mediabot\.conf --generate-migration --types --indexes/,
        'migration README documents index-aware generate-migration');
    $assert->like($migread,
        qr/check_schema_drift\.pl --conf=mediabot\.conf --strict --types --indexes/,
        'migration README documents strict type and index validation');
};
