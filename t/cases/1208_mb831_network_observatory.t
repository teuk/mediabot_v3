use strict;
use warnings;
return sub {
    my ($a)=@_;
    open my $fh,'-|','python3','-B','contrib/network-stats/test_observatory.py'
        or die 'Cannot start observatory regression checks';
    local $/;my $out=<$fh>//'';close $fh;my $exit=$?>>8;
    $a->ok($exit==0,'mb831: raw statistics, remote publisher, scoped upgrade and exact-instance activation contracts');
    print $out if $exit;
};
