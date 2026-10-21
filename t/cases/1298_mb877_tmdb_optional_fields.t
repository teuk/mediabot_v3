use strict;
use warnings;
use Test::More;
use JSON::PP ();
use MB877TMDBFixture qw(run_tmdb tmdb_movie);

for my $bad ([], {}, JSON::PP::true, JSON::PP::false) {
    for my $field (qw(overview release_date)) {
        my $movie = tmdb_movie();
        $movie->{$field} = $bad;
        $movie->{first_air_date} = '2024-02-03';
        my $r = run_tmdb({results => [$movie]});
        ok($r->{ok}, "$field: malformed optional value is contained") or diag($r->{error});
        is_deeply($r->{warnings}, [], "$field: no coercion warning");
        my $want = $field eq 'overview'
            ? '(Reader) [Movie] "Fixture movie" (2026) - Rating: 7.3/10 - No synopsis available.'
            : '(Reader) [Movie] "Fixture movie" (2024) - Rating: 7.3/10 - A complete synopsis.';
        is_deeply($r->{bot}{out}, [['#test', $want]], "$field: invalid value uses the existing fallback without losing healthy metadata");
    }
}
for my $rating ([], {}, JSON::PP::true, JSON::PP::false, 'not rated', '7oops', 'NaN', 'Inf', '-Infinity', '1e99999') {
    my $movie = tmdb_movie();
    $movie->{vote_average} = $rating;
    my $r = run_tmdb({results => [$movie]});
    ok($r->{ok}, 'malformed or non-finite vote remains contained') or diag($r->{error});
    is_deeply($r->{warnings}, [], 'malformed vote is never coerced into a number with warnings');
    is_deeply($r->{bot}{out}, [['#test', '(Reader) [Movie] "Fixture movie" (2026) - Rating: ?/10 - A complete synopsis.']],
        'unusable vote is explicitly unknown instead of zero, a reference address or infinity');
}
for my $row ([0, '0.0'], [7.26, '7.3'], ['8.5', '8.5'], ['8e0', '8.0'], [-1, '-1.0'], [12, '12.0']) {
    my $movie = tmdb_movie();$movie->{vote_average} = $row->[0];
    my $r = run_tmdb({results => [$movie]});
    like($r->{bot}{out}[0][1] // '', qr/Rating: \Q$row->[1]\E\/10/, 'finite numeric values retain their existing one-decimal display, without a new range clamp');
    is_deeply($r->{warnings}, [], 'valid numeric scalar has no warning');
}
for my $absent (0, 1) {
    my $movie = {media_type => 'tv', name => 'Fixture series'};
    $movie->{$_} = undef for $absent ? () : qw(overview release_date first_air_date vote_average);
    my $r = run_tmdb({results => [$movie]});
    is_deeply($r->{bot}{out}, [['#test', '(Reader) [TV Series] "Fixture series" (????) - Rating: ?/10 - No synopsis available.']],
        'missing/null optional metadata keeps the original placeholders');
}
for my $row (['   ', 'No synopsis available.'], ['', 'No synopsis available.'],
    ['0', '0'], [' A complete synopsis. ', ' A complete synopsis. ']) {
    my $movie = tmdb_movie();$movie->{overview} = $row->[0];
    my $r = run_tmdb({results => [$movie]});
    is($r->{bot}{out}[0][1], '(Reader) [Movie] "Fixture movie" (2026) - Rating: 7.3/10 - ' . $row->[1],
        'blank synopsis uses its fallback while zero and meaningful original whitespace remain usable');
}
{
    my $movie = tmdb_movie();
    $movie->{title} = []; $movie->{name} = {}; $movie->{original_title} = 'Original title';
    $movie->{release_date} = {}; $movie->{first_air_date} = [];
    my $r = run_tmdb({results => ['bad', {media_type => 'person'}, $movie]});
    like($r->{bot}{out}[0][1] // '', qr/\[Movie\] "Original title" \(\?\?\?\?\)/,
        'existing result iteration and original-title fallback coexist with an unknown date');
    is(scalar @{$r->{calls}}, 1, 'optional metadata does not trigger a second API request');
    is($r->{options}[0]{timeout}, 10, 'TMDB HTTP timeout remains ten seconds');
    is($r->{options}[0]{verify_SSL}, 1, 'TMDB TLS verification remains enabled');
}
done_testing;
