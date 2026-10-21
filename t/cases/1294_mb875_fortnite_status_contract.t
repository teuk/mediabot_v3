use strict;
use warnings;
use Test::More;
use JSON::PP ();
use MB875FortniteFixture qw(run_fortnite healthy_fortnite);

for my $status ([], {}, JSON::PP::true, JSON::PP::false, undef, '', '200oops', '200.0', '20') {
    my $doc = healthy_fortnite();
    $doc->{status} = $status;
    my $r = run_fortnite($doc);
    ok($r->{ok}, 'malformed API status is contained by the real f handler') or diag($r->{error});
    ok(!defined $r->{result}, 'malformed status cannot declare a successful stats reply');
    is_deeply($r->{bot}{out}, [['#test', 'Fortnite stats: unexpected API response.']],
        'malformed status produces one deterministic response instead of stats or a coerced status');
    is_deeply($r->{warnings}, [], 'malformed status is never numerically coerced');
    unlike(join("\n", @{$r->{bot}{logger}{lines}}), qr/(?:ARRAY|HASH)\(0x|Boolean=/,
        'status diagnostics do not stringify references');
    is(scalar @{$r->{calls}}, 1, 'invalid JSON status does not introduce another API attempt');
    is(scalar @{$r->{bot}{audit}}, 0, 'invalid status never logs a successful stats command');
}

for my $error ([], {}, JSON::PP::true, JSON::PP::false, undef) {
    my $r = run_fortnite({status => 403, error => $error});
    ok($r->{ok}, 'malformed API error value is contained') or diag($r->{error});
    is_deeply($r->{bot}{out}, [['#test', 'Fortnite stats: API error']],
        'non-scalar or null API error uses the existing generic error');
    unlike(join("\n", @{$r->{bot}{logger}{lines}}), qr/(?:ARRAY|HASH)\(0x|Boolean=/,
        'error diagnostics do not stringify references');
    is_deeply($r->{warnings}, [], 'malformed error produces no warning');
}
for my $error ('Account is private', '0', '') {
    my $r = run_fortnite({status => '404', error => $error});
    is_deeply($r->{bot}{out}, [['#test', "Fortnite stats: $error"]],
        'valid scalar API errors retain their existing text, including zero and empty strings');
    is(scalar @{$r->{bot}{audit}}, 0, 'ordinary API failure does not log a successful stats command');
}
my $missing = healthy_fortnite();
delete $missing->{status};
for my $doc (healthy_fortnite(), {%{healthy_fortnite()}, status => '200'}, $missing) {
    my $r = run_fortnite($doc);
    is($r->{result}, 1, 'integer/string success and supported absent status remain usable');
    like($r->{bot}{out}[0][1] // '', qr/Matches:\x0f 120/, 'valid status preserves actual account stats');
    is_deeply($r->{warnings}, [], 'valid statuses have no warnings');
}
for my $args ({unauthenticated => 1}, {denied_level => 1}, {args => []}, {args => ['Unknown']}) {
    my $r = run_fortnite(healthy_fortnite(), %$args);
    ok($r->{ok}, 'existing authentication, level, syntax and user checks remain contained');
    is(scalar @{$r->{calls}}, 0, 'refused command cannot reach the API');
    is(scalar @{$r->{bot}{out}}, 0, 'refused command never publishes stats');
    is(scalar @{$r->{bot}{notices}}, 1, 'refused command retains its private notice');
}
done_testing;
