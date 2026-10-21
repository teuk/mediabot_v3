use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use IPC::Open3;
use Symbol qw(gensym);
use MB877TMDBFixture qw(run_tmdb tmdb_movie);

for my $kind (qw(healthy unicode optional empty wrong_root http_failure)) {
    my $movie = tmdb_movie();
    $movie->{overview} = 'Épopée magique 🎬 ' x 50 if $kind eq 'unicode';
    if ($kind eq 'optional') {
        $movie->{overview} = []; $movie->{release_date} = {}; $movie->{first_air_date} = '2024-02-03';
        $movie->{vote_average} = JSON::PP::true;
    }
    my $doc = $kind eq 'empty' ? {results => []} : $kind eq 'wrong_root' ? [] : {results => [$movie]};
    my %opts = $kind eq 'http_failure' ? (response => {success => 0, status => 503, reason => 'Offline'}) : ();
    my $expected;
    for my $entry (
        ['owner', \&Mediabot::External::TMDB::mbTMDBSearch_ctx],
        ['facade', \&Mediabot::External::mbTMDBSearch_ctx],
        ['legacy', \&Mediabot::External::Claude::mbTMDBSearch_ctx], ['builtin', undef],
    ) {
        my ($label, $handler) = @$entry;
        my $r = run_tmdb($doc, %opts, handler => $handler);
        ok($r->{ok}, "$kind/$label: actual command, parser and renderer execute") or diag($r->{error});
        is_deeply($r->{warnings}, [], "$kind/$label: no warnings");
        my $actual = [$r->{result}, $r->{bot}{out}, $r->{bot}{notices}, $r->{bot}{logger}{lines}, $r->{calls}, $r->{options}];
        if (defined $expected) {
            is_deeply($actual, $expected, "$kind/$label: complete response, diagnostics, target and HTTP match the owner");
        } else {
            $expected = $actual;
            is(scalar @{$r->{calls}}, 1, "$kind/$label: exactly one existing HTTP attempt");
        }
    }
}

# Exercise the real audit against isolated public-source fixtures. Other audit
# sections intentionally lack their sources; inspect this TLS invariant only.
my $root = tempdir('mb878-audit-XXXX', TMPDIR => 1, CLEANUP => 1);
make_path("$root/Mediabot/External");
my %original;
for my $module (qw(Claude TMDB)) {
    my $source = "Mediabot/External/$module.pm";
    open my $fh, '<:raw', $source or die $!;
    $original{$module} = do {local $/; <$fh>};
    close $fh;
    copy($source, "$root/$source") or die $!;
}
sub audit878 {
    my $err = gensym;
    my $pid = open3(undef, my $out, $err, $^X, 'tools/security_audit.pl', '--root', $root);
    my $text = do {local $/; <$out>} // '';
    my $error = do {local $/; <$err>} // '';
    waitpid($pid, 0);
    die $error if length $error;
    return $text;
}
like(audit878(), qr/\[ok\]\s+all \d+ authenticated HTTP calls set verify_SSL => 1/,
    'real TLS audit follows both healthy implementation owners');
for my $module (qw(Claude TMDB)) {
    my $path = "$root/Mediabot/External/$module.pm";
    for my $mutation (qw(tls missing_calls missing_file)) {
        if ($mutation eq 'missing_file') {unlink $path or die $!}
        else {
            my $text = $original{$module};
            my $changed = $mutation eq 'tls'
                ? ($text =~ s/verify_SSL\s*=>\s*1/verify_SSL => 0/)
                : ($text =~ s/_make_http/_removed_factory/g);
            ok($changed, "$module/$mutation: fixture mutation changes actual source");
            open my $fh, '>:raw', $path or die $!;print {$fh} $text;close $fh;
        }
        my $report = audit878();
        if ($mutation eq 'tls') {
            like($report, qr/\[FAIL\].*authenticated HTTP call\(s\) missing verify_SSL => 1/,
                "$module: real audit rejects an unverified authenticated call after extraction");
        } else {
            like($report, qr/\[FAIL\] could not find authenticated _make_http calls in .*\Q$module.pm\E/,
                "$module/$mutation: the other owner cannot mask missing coverage");
        }
        open my $fh, '>:raw', $path or die $!;print {$fh} $original{$module};close $fh;
    }
}
done_testing;
