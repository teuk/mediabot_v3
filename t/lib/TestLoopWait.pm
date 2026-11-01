package TestLoopWait;
use strict;
use warnings;
use Exporter 'import';
use Time::HiRes ();
our @EXPORT_OK=qw(wait_for);

# No clock/timer mock: pump the native loop up to a bounded failure deadline.
# Callers still assert their own complete result, output and resource cleanup.
sub wait_for {
    my ($loop,$complete,$budget)=@_;
    my $end=Time::HiRes::time()+($budget // 3);
    while (!$complete->() && Time::HiRes::time()<$end) {$loop->loop_once(.02)}
    return $complete->()?1:0;
}
1;
