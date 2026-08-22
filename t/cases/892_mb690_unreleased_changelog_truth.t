# t/cases/892_mb690_unreleased_changelog_truth.t
# =============================================================================
# MB690 — every numbered development contract from MB682 onward must be
# represented exactly once in the current public [Unreleased] changelog.
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
    my ($unreleased) = $change =~
        /\Q## [Unreleased] — 3.4dev\E\s*(.*?)(?=^## \[3\.3\](?:\s|$))/ms;

    $assert->ok(defined($unreleased),
        'mb690-892: current 3.4dev Unreleased section is identifiable');
    $unreleased //= '';

    my %mb_from_tests;
    for my $path (glob('t/cases/*_mb*_*.t')) {
        my ($mb) = $path =~ /_mb(\d+)_/i;
        next unless defined $mb && $mb >= 682;
        $mb_from_tests{$mb} = 1;
    }

    $assert->ok(keys(%mb_from_tests) >= 8,
        'mb690-892: development contract discovery finds the MB682+ history');

    for my $mb (sort { $a <=> $b } keys %mb_from_tests) {
        my @headings = $unreleased =~ /^###\s+mb\Q$mb\E\b.*$/gmi;
        $assert->is(
            scalar(@headings), 1,
            "mb690-892: Unreleased documents mb$mb exactly once",
        );
    }

    for my $mb (qw(682 683 684 685 686 687 688 690)) {
        $assert->like(
            $unreleased,
            qr/^###\s+mb\Q$mb\E\b/m,
            "mb690-892: expected recent development entry mb$mb is present",
        );
    }

    my $p690 = index($unreleased, '### mb690 ');
    my $p688 = index($unreleased, '### mb688 ');
    my $p687 = index($unreleased, '### mb687 ');
    my $p686 = index($unreleased, '### mb686 ');
    my $p685 = index($unreleased, '### mb685 ');
    my $p684 = index($unreleased, '### mb684 ');
    my $p683 = index($unreleased, '### mb683 ');
    my $p682 = index($unreleased, '### mb682 ');
    my $p681 = index($unreleased, '### mb681 ');

    $assert->ok(
        $p690 >= 0 && $p688 > $p690 && $p687 > $p688 &&
        $p686 > $p687 && $p685 > $p686 && $p684 > $p685 &&
        $p683 > $p684 && $p682 > $p683 && $p681 > $p682,
        'mb690-892: restored recent entries are in reverse development order',
    );

    $assert->like(
        $unreleased,
        qr/mb689 was an operator-side deployment and\s+lifecycle validation with no repository change/s,
        'mb690-892: deployment-only MB689 is explicitly distinguished from product changes',
    );

    $assert->like(
        $unreleased,
        qr/manual live\s+Debian 13 VM acceptance boundary remains explicit for final 3\.5 readiness/s,
        'mb690-892: current release-gate boundary remains visible in recent history',
    );
};
