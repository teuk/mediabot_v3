# DB-backed timer lifecycle: native DBI, Periodic timers and event loop.
use strict;
use warnings;
BEGIN {use FindBin qw($Bin);unshift @INC,"$Bin/../lib","$Bin/../.."}
use JSON::PP;

return sub {
    my ($assert)=@_;
    open my $probe,'-|',$^X,'-I.','-It/lib','t/lib/MB935TimerAddFixture.pm'
        or die "timer add probe: $!";
    my $raw=do {local $/;<$probe>};my $closed=close $probe;
    my $results=eval {JSON::PP->new->utf8->decode($raw//'')};
    $assert->ok($closed && ref($results) eq 'ARRAY' && @$results==8,
        'MB935: native timer add/remove probe completed');
    for my $row (@{ref($results) eq 'ARRAY' ? $results : []}) {
        $assert->ok($row->{ok},'MB935: '.$row->{name}
            .($row->{detail} ? ': '.$row->{detail} : ''));
    }
};
