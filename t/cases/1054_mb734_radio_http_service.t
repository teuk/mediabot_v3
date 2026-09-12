use strict;
use warnings;
return sub {
    my ($assert)=@_;
    local $ENV{PYTHONDONTWRITEBYTECODE}=1;
    open my $run,'-|','python3','-B','contrib/test_radio_service.py' or die $!;
    local $/; my $output=<$run>//'';
    close $run;
    $assert->is($? >> 8,0,'mb734: durable HTTP service behavior, limits, ownership and failure recovery');
};
