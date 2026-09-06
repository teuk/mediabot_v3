# t/cases/892_mb690_unreleased_changelog_truth.t
# =============================================================================
# MB690 / MB727 — every numbered 3.5 contract from MB682 onward must be
# represented exactly once in the public 3.5 release changelog.
# =============================================================================

use strict;
use warnings;
use utf8;

sub _slurp_892 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $change = _slurp_892('CHANGELOG.md');
    my ($release) = $change =~
        /\Q## [3.5] — 2026-09-06\E\s*(.*?)(?=^## \[3\.3\](?:\s|$))/ms;

    $assert->ok(defined($release),
        'mb690-892: stable 3.5 release section is identifiable');
    $release //= '';

    my %mb_from_tests;
    for my $path (glob('t/cases/*_mb*_*.t')) {
        my ($mb) = $path =~ /_mb(\d+)_/i;
        next unless defined $mb && $mb >= 682;
        $mb_from_tests{$mb} = 1;
    }

    $assert->ok(keys(%mb_from_tests) >= 8,
        'mb690-892: development contract discovery finds the MB682+ history');

    for my $mb (sort { $a <=> $b } keys %mb_from_tests) {
        my @headings = $release =~ /^###\s+mb\Q$mb\E\b.*$/gmi;
        $assert->is(
            scalar(@headings), 1,
            "mb690-892: release 3.5 documents mb$mb exactly once",
        );
    }

    for my $mb (qw(682 683 684 685 686 687 688 690)) {
        $assert->like(
            $release,
            qr/^###\s+mb\Q$mb\E\b/m,
            "mb690-892: expected recent development entry mb$mb is present",
        );
    }

    my $p690 = index($release, '### mb690 ');
    my $p688 = index($release, '### mb688 ');
    my $p687 = index($release, '### mb687 ');
    my $p686 = index($release, '### mb686 ');
    my $p685 = index($release, '### mb685 ');
    my $p684 = index($release, '### mb684 ');
    my $p683 = index($release, '### mb683 ');
    my $p682 = index($release, '### mb682 ');
    my $p681 = index($release, '### mb681 ');

    $assert->ok(
        $p690 >= 0 && $p688 > $p690 && $p687 > $p688 &&
        $p686 > $p687 && $p685 > $p686 && $p684 > $p685 &&
        $p683 > $p684 && $p682 > $p683 && $p681 > $p682,
        'mb690-892: restored recent entries are in reverse development order',
    );

    $assert->like(
        $release,
        qr/mb689 was an operator-side deployment and\s+lifecycle validation with no repository change/s,
        'mb690-892: deployment-only MB689 is explicitly distinguished from product changes',
    );

    $assert->like(
        $release,
        qr/manual live\s+Debian 13 VM acceptance boundary remains explicit for final 3\.5 readiness/s,
        'mb690-892: current release-gate boundary remains visible in recent history',
    );
};
