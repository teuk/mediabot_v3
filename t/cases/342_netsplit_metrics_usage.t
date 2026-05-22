# t/cases/342_netsplit_metrics_usage.t
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_342 {
    open my $fh, '<:encoding(UTF-8)', $_[0] or die $!;
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $metrics  = _slurp_342(File::Spec->catfile('.', 'Mediabot', 'Metrics.pm'));
    my $mediabot = _slurp_342(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
    my $main     = _slurp_342(File::Spec->catfile('.', 'mediabot.pl'));

    $assert->like($metrics, qr/mediabot_netsplit_quits_total/,
        'Metrics declares mediabot_netsplit_quits_total');
    $assert->like($metrics, qr/mediabot_netsplit_rejoins_total/,
        'Metrics declares mediabot_netsplit_rejoins_total');

    $assert->like($main, qr/inc\('mediabot_netsplit_quits_total'\)/,
        'mediabot.pl increments netsplit quit metric');
    $assert->like($mediabot, qr/inc\('mediabot_netsplit_rejoins_total'/,
        'Mediabot.pm increments netsplit rejoin metric');
};
