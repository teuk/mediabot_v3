use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::AI::Request qw(build_request validate_request request_summary);

for my $field (qw(max_output_tokens timeout_seconds)) {
    my $max = $field eq 'max_output_tokens' ? 100_000 : 300;
    for my $value ('1١', '2۲', '1１', '١', '１２', '1e2', '1.5', '+1', '-1',
                   "1\n", '', 0, $max + 1, undef, []) {
        my %args = (messages => [{role => 'user', content => 'Hello'}], $field => $value);
        my (@warnings, $error, $built, $exception, $summary, $key);
        {
            local $SIG{__WARN__} = sub { push @warnings, @_ };
            $error = validate_request(\%args);
            $built = eval { build_request(%args) };
            $exception = $@;
            $summary = request_summary(\%args);
            $key = Mediabot::AI::Request::request_cache_key(\%args, 'test');
        }
        like($error // '', qr/\Q$field\E must be an integer/, "$field rejects malformed or out-of-range input");
        ok(!defined($built) && $exception =~ /invalid AI request/, 'builder rejects invalid limit');
        is($summary, undef, 'invalid request has no summary');
        is($key, undef, 'invalid request has no cache identity');
        is_deeply(\@warnings, [], 'rejection does not emit numeric conversion warnings');
    }
    for my $value (1, '001', 20, "$max") {
        my %args = (messages => [{role => 'user', content => 'Hello'}], $field => $value);
        is(validate_request(\%args), undef, "$field accepts valid ASCII integer");
        my $built = build_request(%args);
        is($built->{$field}, 0 + $value, 'builder preserves numeric value');
        is($args{$field}, $value, 'caller value is unchanged');
        is(validate_request($built), undef, 'built request validates again');
    }
}
done_testing;
