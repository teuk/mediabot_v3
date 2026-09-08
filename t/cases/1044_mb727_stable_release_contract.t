# MB727 — the explicit 3.5 stable release identity and publication boundary.

use strict;
use warnings;
use utf8;

sub _slurp_1044 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $version = _slurp_1044('VERSION');
    my $readme = _slurp_1044('README.md');
    my $change = _slurp_1044('CHANGELOG.md');
    my $roadmap = _slurp_1044('docs/ROADMAP_3.5.md');
    my $releasing = _slurp_1044('docs/RELEASING.md');
    my $notes = _slurp_1044('docs/RELEASE_NOTES_3.5.md');
    my $security = _slurp_1044('.github/SECURITY.md');
    my $workflow = _slurp_1044('.github/workflows/debian13.yml');

    $version =~ s/\s+\z//;
    $assert->like($version, qr/^3\.6dev-[0-9]{8}_[0-9]{6}$/,
        'mb731: master has the timestamped 3.6 development VERSION');

    $assert->like($readme, qr/^3\.5\s+current stable release$/m,
        'mb727: README publishes 3.5 as current stable');
    $assert->like($readme, qr/^3\.6dev\s+current development line$/m,
        'mb731: README exposes the active even development line');
    $assert->like($readme, qr{releases/tag/3\.5},
        'mb727: README links the matching stable release');

    $assert->like($change, qr/^## \[3\.5\] — 2026-09-06$/m,
        'mb727: changelog has a dated 3.5 release heading');
    my @mb727 = $change =~ /^###\s+mb727\b.*$/gmi;
    $assert->is(scalar(@mb727), 1,
        'mb727: changelog records the final gate exactly once');
    $assert->unlike($change, qr/^## \[Unreleased\] — 3\.4dev$/m,
        'mb727: released work is no longer labelled Unreleased');

    $assert->like($security, qr/^\| 3\.5 stable\s+\| Yes\s+\|$/m,
        'mb727: security policy supports stable 3.5');
    $assert->like($security, qr/^\| 3\.6dev\s+\| Yes, development code\s+\|$/m,
        'mb727: security policy and README agree on the next line');

    $assert->like($releasing, qr/^stable version: 3\.5$/m,
        'mb727: release guide records stable 3.5');
    $assert->like($releasing, qr/^Git tag:\s+3\.5$/m,
        'mb727: release guide records the plain 3.5 tag');
    $assert->like($releasing, qr/^archive root:\s+mediabot_v3-3\.5\/$/m,
        'mb727: release guide records the stable archive root');
    $assert->like($releasing, qr/explicit MB727 release decision/,
        'mb727: stable identity derives from the explicit operator gate');

    $assert->like($roadmap,
        qr/^\| MB725 \| Complete \| The exact archived candidate passed/m,
        'mb727: final Debian 13 technical gate is closed');
    $assert->like($roadmap,
        qr/^\| MB727 \| Complete — stable release decision \|/m,
        'mb727: roadmap records the stable release decision');
    for my $work (qw(MB719 MB722)) {
        $assert->like($roadmap, qr/^\| \Q$work\E \| Operator-managed follow-up \|/m,
            "mb727: $work remains operator-managed");
    }
    $assert->like($roadmap,
        qr/does not claim a production deployment/s,
        'mb727: source publication does not forge production evidence');

    $assert->like($notes, qr/^# Mediabot 3\.5\b/m,
        'mb727: public 3.5 release notes exist');
    $assert->like($notes,
        qr/fresh MariaDB installation.*stable 3\.3 database upgrade.*exact rollback.*deterministic reapplication/s,
        'mb727: release notes summarize the Debian acceptance evidence');
    $assert->like($notes,
        qr/Publishing 3\.5 does not deploy or mutate a production instance/,
        'mb727: release notes preserve the operational boundary');

    $assert->like($workflow,
        qr/3\.4dev\|3\.4dev-\*\).*?CANDIDATE_ARGS=\(--rehearsal\).*?3\.5\).*?CANDIDATE_ARGS=\(\)/s,
        'mb727: Debian acceptance supports the final stable VERSION');
    $assert->like($workflow,
        qr/3\.6dev\|3\.6dev-\*\).*?CANDIDATE_VERSION=3\.7.*?CANDIDATE_ARGS=\(--rehearsal\)/s,
        'mb731: Debian acceptance maps 3.6dev to a non-publishable 3.7 rehearsal');
    $assert->like($workflow,
        qr/CANDIDATE_KIND" = rehearsal.*?Rehearsal: yes \(not publishable\).*?Rehearsal: no/s,
        'mb727: Debian acceptance distinguishes rehearsal and stable artifacts');
};
