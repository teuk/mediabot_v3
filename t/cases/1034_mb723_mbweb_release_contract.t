# MB723 — mbweb completes its gated supported promotion before convergence.

use strict;
use warnings;
use utf8;

sub _slurp_1034 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $roadmap = _slurp_1034('docs/ROADMAP_3.5.md');
    my $contract = _slurp_1034('docs/MBWEB_3.5.md');
    my $readme = _slurp_1034('contrib/mbweb/README.md');
    my $change = _slurp_1034('CHANGELOG.md');

    $assert->like($roadmap,
        qr/^\| MB723 \| Complete — supported \| All four gates passed/m,
        'mb723: roadmap records the explicit supported outcome');
    $assert->like($roadmap,
        qr/returned to the 3\.5 path as a \*\*supported candidate\*\* and is now an\s+accepted supported component/s,
        'mb723: candidate status advances only after recorded acceptance');

    for my $gate (qw(MB723-A MB723-B MB723-C MB723-D)) {
        $assert->like($roadmap, qr/\*\*\Q$gate\E\b/,
            "mb723: roadmap names $gate");
        $assert->like($contract, qr/^## \Q$gate\E\b/m,
            "mb723: detailed contract defines $gate");
    }

    my $p_mb723 = index($roadmap, '| MB723 | Complete — supported |');
    my $p_mb724 = index($roadmap, '| MB724 | Complete on development |');
    my $p_mb722 = index($roadmap, '| MB722 | P0 |');
    my $p_mb726 = index($roadmap, '| MB726 | P1 |');
    my $p_mb725 = index($roadmap, '| MB725 | Final technical gate |');
    my $p_mb727 = index($roadmap, '| MB727 | Final |');
    $assert->ok(
        $p_mb723 >= 0 && $p_mb723 < $p_mb724
            && $p_mb724 < $p_mb722 && $p_mb722 < $p_mb726
            && $p_mb726 < $p_mb725 && $p_mb725 < $p_mb727,
        'mb723: accepted qualification, hardening, convergence, dry run and final install are ordered');

    $assert->like($roadmap,
        qr/MB722 must not start while MB723 or MB724 is open/,
        'mb723: convergence cannot hide an incomplete supported surface');
    $assert->like($roadmap,
        qr/Run MB725 last: a fresh Debian 13 installation.*3\.3-to-3\.5 upgrade/s,
        'mb723: Debian 13 stays the last technical gate');

    $assert->like($contract,
        qr/Production must refuse the default in-memory session store/,
        'mb723: production session storage fails closed');
    $assert->like($contract,
        qr/Every state-changing route uses a session-bound CSRF token/,
        'mb723: state changes share one CSRF boundary');
    $assert->like($contract,
        qr/Logout becomes a protected POST/,
        'mb723: logout is no longer a state-changing GET');
    $assert->like($contract,
        qr/does not add a general bot-control API/,
        'mb723: pilot stays observational');
    $assert->like($contract,
        qr/mbweb must not interrupt Mediabot.*prevent an\s+instance from starting/s,
        'mb723: web failure cannot become an IRC dependency');
    $assert->like($contract,
        qr/The recorded outcome is \*\*supported\*\*/,
        'mb723: promotion records exactly the accepted outcome');
    $assert->like($contract,
        qr/joins the complete\s+surface exercised by MB724 and later converged under MB722/s,
        'mb723: accepted mbweb joins the later gates');

    $assert->like($readme,
        qr/accepted into the Mediabot 3\.5 supported\s+surface after MB723-A through MB723-D/s,
        'mb723: mbweb README records the supported boundary');
    $assert->like($readme,
        qr/Promotion keeps the console read-only by default/,
        'mb723: mbweb README preserves read-only promotion');

    my @entries = $change =~ /^###\s+mb723\b.*$/gmi;
    $assert->is(scalar(@entries), 1,
        'mb723: Unreleased changelog contains one promotion entry');
};
