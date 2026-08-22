# t/cases/885_mb683_security_policy_version_sync.t
# =============================================================================
# MB683 — public security policy must track the public release-status contract.
# Documentation/metadata only: no runtime behavior is exercised here.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_885 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $readme = _slurp_885(File::Spec->catfile('.', 'README.md'));
    my $policy = _slurp_885(File::Spec->catfile('.', '.github', 'SECURITY.md'));

    my ($stable) = $readme =~ /^\s*(\d+\.\d+)\s+current stable release\s*$/m;
    my ($dev)    = $readme =~ /^\s*(\d+\.\d+dev)\s+next development line\s*$/m;

    $assert->ok(defined($stable), 'README exposes the current stable release');
    $assert->ok(defined($dev),    'README exposes the active development line');

    $stable //= '';
    $dev    //= '';

    $assert->like(
        $policy,
        qr/^\|\s*\Q$stable\E stable\s*\|\s*Yes\s*\|$/m,
        'security policy supports the same stable version as README',
    );

    $assert->like(
        $policy,
        qr/^\|\s*\Q$dev\E\s*\|\s*Yes, development code\s*\|$/m,
        'security policy supports the same development line as README',
    );

    $assert->like(
        $policy,
        qr/This table mirrors the public release status in `README\.md`/,
        'security policy documents the cross-document version contract',
    );

    $assert->unlike(
        $policy,
        qr/^\|\s*3\.1 stable\s*\|/m,
        'obsolete 3.1 stable support row is gone',
    );

    $assert->unlike(
        $policy,
        qr/^\|\s*3\.2-dev\s*\|/m,
        'obsolete 3.2-dev support row is gone',
    );

    $assert->like(
        $policy,
        qr/GitHub's \*\*private vulnerability reporting\*\* feature/,
        'private vulnerability reporting remains the security-reporting path',
    );

    $assert->like(
        $policy,
        qr/Do not include real passwords, API keys, IRC credentials, database credentials, authentication tokens, cookies, private keys or personal data\./,
        'security report guidance still forbids real secrets/personal data',
    );

    $assert->like(
        $policy,
        qr/\*\*Network:\*\* EpiKnet.*\*\*Port:\*\* `6697`.*\*\*Encryption:\*\* SSL\/TLS.*\*\*Channel:\*\* `#i\/o`/s,
        'public support contact remains the documented encrypted EpiKnet channel',
    );
};
