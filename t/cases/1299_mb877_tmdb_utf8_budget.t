use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode decode FB_CROAK);
use MB877TMDBFixture qw(run_tmdb tmdb_movie);
use Mediabot::Helpers ();

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

for my $text ('é' x 250, '🎬' x 150, ('Épopée magique 🎬 ' x 45), ('界' x 200)) {
    for my $budget (120, 240, 400) {
        my $movie = tmdb_movie();$movie->{overview} = $text;
        my $r = run_tmdb({results => [$movie]}, maxlen => $budget, nick => 'LecteurÉ');
        ok($r->{ok}, "UTF-8/$budget: actual TMDB handler completes") or diag($r->{error});
        is(scalar @{$r->{bot}{out}}, 1, "UTF-8/$budget: one complete command payload");
        my $line = $r->{bot}{out}[0][1] // '';
        my $wire = encode('UTF-8', $line);
        cmp_ok(length($wire), '<=', $budget, "UTF-8/$budget: complete reply fits the byte budget including its prefix and suffix");
        ok(eval {decode('UTF-8', $wire, FB_CROAK); 1}, "UTF-8/$budget: output contains complete UTF-8 characters");
        like($line, qr/[.]{3}\z/, "UTF-8/$budget: truncation remains visible");
        my @chunks = Mediabot::Helpers::_split_text_for_irc($line, 400);
        is(scalar @chunks, 1, "UTF-8/$budget: normal IRC splitting cannot create an unplanned second message");
    }
}
for my $part (qw(title nickname)) {
    my $movie = tmdb_movie();
    my %args = (maxlen => 120);
    if ($part eq 'title') {$movie->{title} = '🎬' x 80} else {$args{nick} = 'É' x 80}
    my $r = run_tmdb({results => [$movie]}, %args);
    my $line = $r->{bot}{out}[0][1] // '';
    cmp_ok(length(encode('UTF-8', $line)), '<=', 120, "$part: overlong Unicode prefix is bounded too");
    like($line, qr/[.]{3}\z/, "$part: overlong prefix still gets its ellipsis");
}
for my $row ([80,120], [120,120], [900,900], [5000,900]) {
    my ($configured,$limit) = @$row;
    my $movie=tmdb_movie();$movie->{overview}='界' x 1100;
    my $r=run_tmdb({results=>[$movie]},maxlen=>$configured);
    cmp_ok(length(encode('UTF-8',$r->{bot}{out}[0][1] // '')), '<=', $limit,
        'existing configuration minimum and maximum apply to encoded bytes');
}
{
    my $r=run_tmdb({results=>[tmdb_movie()]});
    is_deeply($r->{bot}{out}, [['#test', '(Reader) [Movie] "Fixture movie" (2026) - Rating: 7.3/10 - A complete synopsis.']],
        'a healthy short reply stays byte-for-byte unchanged');
    my $movie=tmdb_movie();$movie->{overview}='A precise synopsis with plain words. ' x 20;
    $r=run_tmdb({results=>[$movie]},maxlen=>120);
    is($r->{bot}{out}[0][1], '(Reader) [Movie] "Fixture movie" (2026) - Rating: 7.3/10 - A precise synopsis with plain words. A precise synopsis...',
        'long ASCII reply retains its established word boundary and three dots');
}
done_testing;
