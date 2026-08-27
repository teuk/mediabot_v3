use strict;
use warnings;
use utf8;

sub _slurp_967 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $schema = _slurp_967('install/mediabot.sql');
    my $mig    = _slurp_967('install/migrations/20260827_vdm_chanset.sql');
    my $mread  = _slurp_967('install/migrations/README.md');
    my $dbdoc  = _slurp_967('docs/DB_MIGRATIONS.md');
    my $cl     = _slurp_967('CHANGELOG.md');

    $assert->like($schema, qr/\(26,\s*'VDM'\)[,;]/,
        'mb704-967: fresh schema keeps VDM as canonical chanset id 26 even when later chansets follow');
    $assert->like($mig, qr/INSERT INTO CHANSET_LIST \(chanset\).*?SELECT 'VDM'/s,
        'mb704-967: upgrade migration registers VDM idempotently');
    $assert->like($mig, qr/WHERE NOT EXISTS\s*\(.*?chanset = 'VDM'/s,
        'mb704-967: VDM migration is safe to re-run');
    $assert->unlike($mig, qr/INSERT\s+INTO\s+CHANNEL_SET/i,
        'mb704-967: migration does not opt channels into VDM');
    $assert->like($mread, qr/^20260827_vdm_chanset\.sql$/m,
        'mb704-967: migration inventory includes VDM');
    $assert->like($dbdoc, qr/20260827_vdm_chanset\.sql/,
        'mb704-967: database guide includes VDM');
    $assert->like($cl, qr/### mb704 —/,
        'mb704-967: changelog documents MB704 foundation');
};
