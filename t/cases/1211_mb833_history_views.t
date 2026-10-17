use strict;
use warnings;
return sub {
    my ($a)=@_;
    open my $fh,'-|','python3','-B','contrib/network-stats/test_history_views.py'
        or die 'Cannot start historical-view regression checks';
    local $/;my $out=<$fh>//'';close $fh;my $exit=$?>>8;
    $a->ok($exit==0,'mb833: bounded history, disjoint comparison periods, raw statistics and public API contracts');
    print $out if $exit;
};
