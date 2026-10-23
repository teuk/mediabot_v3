# Late VDM delivery: native worker transport and real IRC lifecycle state.
use strict;
use warnings;
BEGIN {use FindBin qw($Bin);unshift @INC,"$Bin/../lib","$Bin/../.."}
use JSON::PP;

return sub {
    my ($assert)=@_;
    open my $probe,'-|',$^X,'-I.','-It/lib','t/lib/MB936VDMDeliveryFixture.pm'
        or die "VDM delivery probe: $!";
    my $raw=do {local $/;<$probe>};my $closed=close $probe;
    my $results=eval {JSON::PP->new->utf8->decode($raw//'')};
    $assert->ok($closed && ref($results) eq 'ARRAY' && @$results==8,
        'MB936: native VDM delivery probe completed');
    for my $row (@{ref($results) eq 'ARRAY' ? $results : []}) {
        $assert->ok($row->{ok},'MB936: '.$row->{name}
            .($row->{detail} ? ': '.$row->{detail} : ''));
    }
};
