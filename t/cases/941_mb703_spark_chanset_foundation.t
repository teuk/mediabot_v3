# t/cases/941_mb703_spark_chanset_foundation.t
# =============================================================================
# MB703-A1 — register +Spark as a default-off channel capability.
# =============================================================================

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

sub _slurp_941 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $schema = _slurp_941('install/mediabot.sql');
    my $mig    = _slurp_941('install/migrations/20260827_spark_chanset.sql');
    my $mread  = _slurp_941('install/migrations/README.md');
    my $dbdoc  = _slurp_941('docs/DB_MIGRATIONS.md');
    my $cl     = _slurp_941('CHANGELOG.md');

    $assert->like($schema, qr/\(25,\s*'Spark'\);/,
        'mb703-941: fresh schema registers Spark as chanset id 25');
    $assert->like($mig, qr/INSERT INTO CHANSET_LIST \(chanset\).*?SELECT 'Spark'/s,
        'mb703-941: upgrade migration registers Spark idempotently');
    $assert->like($mig, qr/WHERE NOT EXISTS\s*\(.*?chanset = 'Spark'/s,
        'mb703-941: migration is safe to re-run');
    $assert->unlike($mig, qr/INSERT\s+INTO\s+CHANNEL_SET/i,
        'mb703-941: migration does not opt any channel in automatically');
    $assert->like($mread, qr/^20260827_spark_chanset\.sql$/m,
        'mb703-941: migration inventory includes Spark');
    $assert->like($dbdoc, qr/20260827_spark_chanset\.sql/,
        'mb703-941: DB migration guide includes Spark');
    $assert->like($cl, qr/### mb703 —/, 'mb703-941: changelog documents MB703');
};
