use strict;
use warnings;
use utf8;

sub slurp_986 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;
    my $main = slurp_986('Mediabot/Mediabot.pm');
    my $schema = slurp_986('install/mediabot.sql');
    my $mig = slurp_986('install/migrations/20260827_danstonchat_chanset.sql');
    my $readme = slurp_986('install/migrations/README.md');

    $assert->like($main, qr/use Mediabot::DTC::Commands \(\);/,
        'mb707-986: native DTC command module is loaded');
    $assert->like($main, qr/^\s*dtc\s*=>\s*sub \{ Mediabot::DTC::Commands::dispatch_ctx\(\$ctx\) \}/m,
        'mb707-986: !dtc routes to the native command');
    $assert->like($main, qr/^\s*bashfr\s*=>\s*sub \{ Mediabot::DTC::Commands::dispatch_ctx\(\$ctx\) \}/m,
        'mb707-986: !bashfr is the same native route');
    $assert->like($schema, qr/\(27, 'DansTonChat'\)/,
        'mb707-986: fresh schema contains DansTonChat chanset');
    $assert->like($mig, qr/INSERT INTO CHANSET_LIST.*?'DansTonChat'/s,
        'mb707-986: idempotent existing-install migration registers DansTonChat');
    $assert->like($readme, qr/^20260827_danstonchat_chanset\.sql$/m,
        'mb707-986: migration is in authoritative order');
};
