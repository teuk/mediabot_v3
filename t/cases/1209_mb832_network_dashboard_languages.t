use strict;
use warnings;
return sub {
    my ($a)=@_;
    open my $fh,'-|','node','--test','contrib/network-stats/test_dashboard_i18n.js'
        or die 'Cannot start dashboard language regression checks';
    local $/;my $out=<$fh>//'';close $fh;my $exit=$?>>8;
    $a->ok($exit==0,'mb832: English default, complete French, private persistent choice and stable data semantics');
    print $out if $exit;
};
