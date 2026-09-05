# MB724 — the source audit covers the complete accepted 3.5 surface.

use strict;
use warnings;
use utf8;

sub _slurp_1039 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $audit = _slurp_1039('tools/security_audit.pl');
    my $doc = _slurp_1039('docs/B3_revue_securite.md');
    my $roadmap = _slurp_1039('docs/ROADMAP_3.5.md');
    my $changelog = _slurp_1039('CHANGELOG.md');

    my @axes = (
        '[1] Secrets never logged in clear',
        '[2] TLS verification secure by default',
        '[3] External commands run without a shell',
        '[4] CR/LF/NUL sanitisation on IRC output',
        '[5] Process lock (single instance)',
        '[6] HTTP download caps',
        '[7] Authentication throttling',
        '[8] Bounded workers and script execution',
        '[9] HTTP and provider-neutral AI boundaries',
        '[10] Hailo isolation and deterministic fallback',
        '[11] Privacy-safe aggregate observability',
        '[12] Privileged interfaces fail closed',
        '[13] systemd identities and writable paths',
        '[14] Restore and public archive boundaries',
        '[15] mbweb session and request boundaries',
        '[16] Database reference and read-only diagnosis',
    );

    for my $axis (@axes) {
        $assert->like($audit, qr/\Q$axis\E/,
            "mb724a: audit exposes $axis");
    }

    $assert->like($audit, qr/Mediabot cross-cutting security audit \(B3 \+ MB724\)/,
        'mb724a: audit identifies the cross-cutting 3.5 gate');
    $assert->like($audit, qr/AsyncWorker enforces timeout, output cap and TERM\/KILL escalation/,
        'mb724a: isolated worker lifecycle is covered');
    $assert->like($audit, qr/AI failure envelopes expose only the bounded diagnostic tuple/,
        'mb724a: provider errors retain their privacy boundary');
    $assert->like($audit, qr/Hailo summaries and logs exclude trigger, draft, edited line and context text/,
        'mb724a: Hailo observability rejects raw conversation content');
    $assert->like($audit, qr/Fullop delegation is enabled-only, one-shot and refuses unmanaged bans/,
        'mb724a: Fullop service delegation and persistence are covered');
    $assert->like($audit, qr/release archives are commit-derived, deterministic and reject private\/generated material/,
        'mb724a: public archive privacy is covered');
    $assert->like($audit, qr/mbweb production sessions require the durable MySQL store before listen/,
        'mb724a: mbweb durable session readiness is covered');
    $assert->like($audit, qr/Doctor enforces a read-only session and delegates types\/indexes/,
        'mb724a: database inspection remains read-only and reference-backed');

    $assert->like($audit, qr/Verdict: NO-GO/,
        'mb724a: source audit remains fail-closed');
    $assert->like($audit, qr/exit 1/,
        'mb724a: failed source audit returns non-zero');
    $assert->like($audit, qr/--warn-only/,
        'mb724a: exploratory warn-only mode remains explicit');
    $assert->unlike($audit, qr/use\s+(?:HTTP::Tiny|IO::Socket|DBI)\b/,
        'mb724a: source audit itself opens no network or database connection');

    $assert->like($doc, qr/Les 37 invariants sont regroupés en 16 axes/,
        'mb724a: operator documentation records the exact matrix size');
    $assert->like($doc, qr/Le résultat source ne suffit pas à fermer MB724/,
        'mb724a: documentation preserves the operational evidence boundary');
    $assert->like($doc, qr/ni secret, ni conversation, ni cookie/,
        'mb724a: operational evidence privacy is explicit');
    $assert->like($doc, qr/MB724 n'absorbe pas MB719/,
        'mb724: known schema drift remains under the MB719 authority');
    $assert->like($doc, qr/La full suite reste réservée/,
        'mb724a: full-suite boundary remains explicit');

    $assert->like($roadmap, qr/^\| MB724 \| Complete on development \|/m,
        'mb724: roadmap records the complete source and operational gate');
    $assert->unlike($roadmap, qr/^\| MB724(?:-B)? \| P0 \|/m,
        'mb724: roadmap has no open MB724 sub-gate');
    $assert->like($roadmap, qr/MB722 must not start while MB723 or MB724 is open/,
        'mb724a: convergence cannot absorb an unfinished operational gate');
    $assert->like($changelog, qr/^### mb724 — exercise the cross-cutting 3[.]5 security contract$/m,
        'mb724: changelog records the bounded source and operational gate');
};
