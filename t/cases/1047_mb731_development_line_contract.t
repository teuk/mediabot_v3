# t/cases/1047_mb731_development_line_contract.t
# =============================================================================
# MB731 — master opens 3.6dev while stable 3.5 remains published and the
# Debian 13 gate packages development only as a non-publishable 3.7 rehearsal.
# =============================================================================

use strict;
use warnings;
use utf8;

sub _slurp_1047 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $version = _slurp_1047('VERSION');
    my $readme = _slurp_1047('README.md');
    my $change = _slurp_1047('CHANGELOG.md');
    my $workflow = _slurp_1047('.github/workflows/debian13.yml');

    $version =~ s/\s+\z//;
    $assert->like($version, qr/^3\.6dev-[0-9]{8}_[0-9]{6}$/,
        'mb731-1047: source carries a timestamped 3.6dev identity');
    $assert->like($readme, qr/^3\.5\s+current stable release$/m,
        'mb731-1047: README keeps 3.5 as current stable');
    $assert->like($readme, qr/^3\.6dev\s+current development line$/m,
        'mb731-1047: README exposes 3.6dev as current development');
    $assert->like($change, qr/^## \[Unreleased\] — 3\.6dev$/m,
        'mb731-1047: changelog opens the 3.6dev section');
    my @entries = $change =~ /^###\s+mb731\b.*$/gmi;
    $assert->is(scalar(@entries), 1,
        'mb731-1047: changelog documents mb731 exactly once');
    $assert->like($workflow,
        qr/3\.6dev\|3\.6dev-\*\).*?CANDIDATE_VERSION=3\.7.*?CANDIDATE_KIND=rehearsal.*?CANDIDATE_ARGS=\(--rehearsal\)/s,
        'mb731-1047: Debian gate maps 3.6dev to a 3.7 rehearsal');
    $assert->like($workflow,
        qr/3\.5\).*?CANDIDATE_VERSION=3\.5.*?CANDIDATE_KIND=stable.*?CANDIDATE_ARGS=\(\)/s,
        'mb731-1047: exact stable 3.5 packaging remains supported');
};
