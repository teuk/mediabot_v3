use strict;
use warnings;

return sub {
    my ($assert) = @_;
    local $ENV{PYTHONDONTWRITEBYTECODE} = 1;
    open my $run, '-|', 'python3', '-B', 'contrib/shorturl/test_shorturl_service.py'
        or die $!;
    local $/;
    my $output = <$run> // '';
    close $run;
    $assert->is($? >> 8, 0,
        'mb736: private creation API, public redirects, limits and destination safety');
};
