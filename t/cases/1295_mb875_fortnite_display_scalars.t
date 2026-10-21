use strict;
use warnings;
use Test::More;
use JSON::PP ();
use MB875FortniteFixture qw(run_fortnite healthy_fortnite);

my $expected = 'Fortnite -- [Player] Matches: 120 | Wins: 10 (8.3%) | Kills: 345 | K/D: 3.14 | BP: L42 (75%) | Top3/5/10: 12/23/34';
my @fields = (
    [account => 'name', '[Player]', '[Target]'],
    [overall => 'matches', 'Matches: 120', 'Matches: 0'],
    [overall => 'wins', 'Wins: 10', 'Wins: 0'],
    [overall => 'winRate', '(8.3%)', '(0%)'],
    [overall => 'kills', 'Kills: 345', 'Kills: 0'],
    [overall => 'kd', 'K/D: 3.14', 'K/D: 0'],
    [overall => 'top3', '12/23/34', '0/23/34'],
    [overall => 'top5', '12/23/34', '12/0/34'],
    [overall => 'top10', '12/23/34', '12/23/0'],
    [battlePass => 'level', 'L42', 'L0'],
    [battlePass => 'progress', '(75%)', '(0%)'],
);
for my $field (@fields) {
    my ($section, $key, $old, $replacement) = @$field;
    for my $bad ([], {}, JSON::PP::true, JSON::PP::false) {
        my $doc = healthy_fortnite();
        my $node = $section eq 'overall' ? $doc->{data}{stats}{all}{overall} : $doc->{data}{$section};
        $node->{$key} = $bad;
        my $r = run_fortnite($doc);
        my $line = $r->{bot}{out}[0][1] // '';
        $line =~ s/[\x02\x0f]//g;
        (my $want = $expected) =~ s/\Q$old\E/$replacement/;
        is($r->{result}, 1, "$section.$key: malformed leaf does not discard other usable stats");
        is_deeply($r->{warnings}, [], "$section.$key: references never reach numeric formatting");
        is($line, $want, "$section.$key: only the malformed leaf uses its existing missing-field default");
        is(scalar @{$r->{bot}{out}}, 1, "$section.$key: f retains one stats reply");
    }
}
for my $absent (0, 1) {
    my $doc = healthy_fortnite();
    for my $field (@fields) {
        my ($section, $key) = @$field;
        my $node = $section eq 'overall' ? $doc->{data}{stats}{all}{overall} : $doc->{data}{$section};
        if ($absent) { delete $node->{$key} } else { $node->{$key} = undef }
    }
    my $r = run_fortnite($doc);
    (my $line = $r->{bot}{out}[0][1] // '') =~ s/[\x02\x0f]//g;
    is($line, 'Fortnite -- [Target] Matches: 0 | Wins: 0 (0%) | Kills: 0 | K/D: 0 | BP: L0 (0%) | Top3/5/10: 0/0/0',
        'missing and null fields keep the original defaults');
}
for my $mode (qw(overall solo duo trio squad)) {
    my $doc = healthy_fortnite();
    my $overall = delete $doc->{data}{stats}{all}{overall};
    $doc->{data}{stats}{all}{$mode} = $overall;
    my $r = run_fortnite($doc, channel => undef);
    (my $line = $r->{bot}{out}[0][1] // '') =~ s/[\x02\x0f]//g;
    is($line, $expected, "$mode: existing mode selection and rounded healthy output remain exact");
    is($r->{bot}{out}[0][0], 'Reader', "$mode: private command retains its current reply target");
    is(scalar @{$r->{bot}{audit}}, 1, "$mode: successful command still logs once");
}
{
    my $doc = healthy_fortnite();
    $doc->{data}{account}{name} = '0';
    $doc->{data}{stats}{all}{overall}{kd} = 'n/a';
    $doc->{data}{stats}{all}{overall}{winRate} = 0;
    my $r = run_fortnite($doc);
    like($r->{bot}{out}[0][1] // '', qr/\[0\].*\(0%\).*K\/D:\x0f n\/a/, 'scalar zero and legacy non-numeric scalar display stay compatible');
    is($r->{options}[0]{timeout}, 10, 'HTTP timeout remains ten seconds');
    is($r->{options}[0]{verify_SSL}, 1, 'API TLS verification remains enabled');
    is(scalar @{$r->{calls}}, 1, 'healthy stats need one request');
    is($r->{calls}[0][0], 'https://fortnite-api.com/v2/stats/br/v2/fixture-account', 'real SQLite account lookup selects the exact existing endpoint');
    ok(exists $r->{calls}[0][1]{headers}{Authorization}, 'existing API authorization header is retained');
}
done_testing;
