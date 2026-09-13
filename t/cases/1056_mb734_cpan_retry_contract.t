use strict;
use warnings;
return sub {
    my ($assert)=@_;
    local $ENV{PYTHONDONTWRITEBYTECODE}=1;
    open my $run,'-|','python3','-B','contrib/test_ci_cpan_retry.py' or die $!;
    local $/; my $output=<$run>//'';
    close $run;
    my $rc=$? >> 8;
    $assert->diag($output) if $rc;
    $assert->is($rc,0,'mb734: HTTPS CPAN, fresh retry state, bounded failures and module verification');
};
