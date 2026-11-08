use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::Hailo::Normalizer qw(rehydrate_hailo_output);

for my $digits ('٠١', '１２', '१२', '𝟙𝟚', '0١', '１0') {
    my $token = "zzhailonick${digits}zz";
    my @warnings;
    my $out;
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $out = rehydrate_hailo_output(channel => '#test', speaker => 'Alice',
            text => "Hello $token today", bucket_nicks => {zzhailonick00zz => ['Bob'], $token => ['Carol']});
    }
    ok($out->{ok}, 'literal Unicode token-like text is accepted');
    is($out->{line}, "Hello $token today", 'non-ASCII token is not converted to another nickname');
    is_deeply(\@warnings, [], 'no numeric conversion warnings');
}
for my $bucket (0 .. 31) {
    my $token = sprintf('zzhailonick%02dzz', $bucket);
    my $out = rehydrate_hailo_output(channel => '#test',
        text => "Hello $token today", bucket_nicks => {$token => ['Bob']});
    is($out->{line}, 'Hello Bob today', 'valid ASCII bucket restores its nickname');
    $out = rehydrate_hailo_output(channel => '#test', speaker => 'Alice', text => "Hello $token today");
    is($out->{line}, 'Hello Alice today', 'valid ASCII bucket retains speaker fallback');
}
done_testing;
