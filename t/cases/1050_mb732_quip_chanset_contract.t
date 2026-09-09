use strict;
use warnings;
use utf8;

sub _slurp_1050 {
    my($path)=@_;open my $fh,'<:encoding(UTF-8)',$path or die "$path: $!";local $/;return <$fh>;
}

return sub {
    my($a)=@_;
    my $schema=_slurp_1050('install/mediabot.sql');
    my $migration=_slurp_1050('install/migrations/20260909_quip_chanset.sql');
    my @fresh=$schema =~ /^\(\d+,\s*'Quip'\)[,;]/mg;
    $a->is(scalar @fresh,1,'mb732: fresh schema registers exactly one Quip capability');
    $a->like($migration,qr/INSERT INTO CHANSET_LIST \(chanset\).*SELECT 'Quip'.*WHERE NOT EXISTS.*chanset = 'Quip'/s,'mb732: upgrade is idempotent by name');
    $a->unlike($migration,qr/\b(?:CREATE|ALTER|DROP|TRUNCATE|RENAME)\b/i,'mb732: registration performs no DDL');
    $a->unlike($migration,qr/\b(?:INSERT|UPDATE|DELETE|REPLACE)\b[^;]*\bCHANNEL_SET\b/is,'mb732: registration enables no channel');
    for my $path ('docs/DB_MIGRATIONS.md','install/migrations/README.md') {
        $a->like(_slurp_1050($path),qr/^20260909_quip_chanset\.sql$/m,'mb732: authoritative migration inventory includes Quip');
    }
    $a->like(_slurp_1050('docs/DB_MIGRATIONS.md'),qr{SOURCE /home/mediabot/mediabot_v3/install/migrations/20260909_quip_chanset\.sql;},'mb732: operator guide includes the explicit migration');
    my $sample=_slurp_1050('mediabot.sample.conf');
    $a->like($sample,qr/^WIT_SEND_ARMED=0$/m,'mb732: shared master remains disabled in sample configuration');
    $a->unlike($sample,qr/^QUIP_(?:API_KEY|PROVIDER|SEND_ARMED)=/m,'mb732: no parallel provider or sender configuration is introduced');
    my $change=_slurp_1050('CHANGELOG.md');
    my @entries=$change =~ /^### mb732\b/gm;
    $a->is(scalar @entries,1,'mb732: changelog contains one entry');
    $a->like($change,qr/^## \[Unreleased\].*?^### mb732.*?^## \[3\.5\]/ms,'mb732: change belongs to development, not the frozen stable release');
};
