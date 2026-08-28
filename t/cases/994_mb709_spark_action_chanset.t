# t/cases/994_mb709_spark_action_chanset.t
use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

return sub {
    my ($assert) = @_;

    my $read = sub {
        my ($rel) = @_;
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../$rel"
            or die "open $rel: $!";
        local $/;
        return <$fh>;
    };

    my $schema = $read->('install/mediabot.sql');
    my $migration = $read->(
        'install/migrations/20260828_spark_action_chanset.sql'
    );
    my $migration_index = $read->('install/migrations/README.md');
    my $migration_doc = $read->('docs/DB_MIGRATIONS.md');
    my $changelog = $read->('CHANGELOG.md');

    $assert->like($schema, qr/\(28,\s*'SparkAction'\)/,
        'mb709-994: fresh schema registers SparkAction with stable id 28');
    $assert->is(scalar(() = $schema =~ /\(28,\s*'SparkAction'\)/g), 1,
        'mb709-994: fresh schema contains one SparkAction row');
    $assert->like(
        $migration,
        qr/INSERT\s+INTO\s+CHANSET_LIST.*?SELECT\s+'SparkAction'.*?NOT\s+EXISTS/is,
        'mb709-994: upgrade migration is idempotent and data-only');
    $assert->unlike($migration, qr/\bCHANNEL_SET\b/,
        'mb709-994: migration cannot opt any existing channel in');
    $assert->like($migration_index, qr/20260828_spark_action_chanset\.sql/,
        'mb709-994: migration index exposes the new upgrade step');
    $assert->like($migration_doc, qr/20260828_spark_action_chanset\.sql/,
        'mb709-994: operator migration order includes the new upgrade step');
    $assert->like($changelog, qr/\+SparkAction.*second channel opt-in/s,
        'mb709-994: changelog documents the independent second opt-in');
    $assert->like($changelog, qr/Added dry-run-only runtime wiring.*?No active-action selector/s,
        'mb709-994: changelog states the no-public-action boundary');
};
