use strict;
use warnings;
return sub {
    my ($a)=@_;
    open my $fh,'-|','node','--test','contrib/network-stats/test_history_views.js'
        or die 'Cannot start history dashboard regression checks';
    local $/;my $out=<$fh>//'';close $fh;my $exit=$?>>8;
    $a->ok($exit==0,'mb833: sample-aware means, safe public view links, actual prior observations and bilingual guidance');
    print $out if $exit;
};
