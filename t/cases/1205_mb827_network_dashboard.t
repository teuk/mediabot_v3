use strict;
use warnings;
return sub {
    my ($a)=@_;
    open my $fh,'-|','python3','-B','contrib/network-stats/test_network_stats.py' or die 'Cannot run network stats integration tests';
    local $/;my $out=<$fh>//'';close $fh;my $exit=$?>>8;
    $a->ok($exit==0,'mb827: real HTTP, SQLite history, publisher recovery and scoped installation contracts');
    print $out if $exit;
};
