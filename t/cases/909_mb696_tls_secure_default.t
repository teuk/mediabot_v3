# t/cases/909_mb696_tls_secure_default.t
# =============================================================================
# mb696 — TLS is secure by default.
#
# The shared HTTP factory verifies certificates unless a caller explicitly
# opts out. The only reviewed opt-out remains the configurable Icecast client;
# authenticated Tavily and direct country.is HTTPS calls are explicitly secure.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use File::Spec;

sub _slurp_909 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path
        or die "$path: $!";

    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    require Mediabot::External;

    my $default =
        Mediabot::External::_make_http(timeout => 1);

    my $unsafe =
        Mediabot::External::_make_http(
            timeout    => 1,
            verify_SSL => 0,
        );

    $assert->ok(
        $default->{verify_SSL},
        'mb696-909: shared HTTP factory verifies TLS by default'
    );

    $assert->ok(
        !$unsafe->{verify_SSL},
        'mb696-909: explicit compatibility opt-out remains possible'
    );

    my $external = _slurp_909(
        File::Spec->catfile('.', 'Mediabot', 'External.pm')
    );

    my $news = _slurp_909(
        File::Spec->catfile(
            '.', 'Mediabot', 'External', 'News.pm'
        )
    );

    my $helpers = _slurp_909(
        File::Spec->catfile('.', 'Mediabot', 'Helpers.pm')
    );

    my $admin = _slurp_909(
        File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm')
    );

    my $audit = _slurp_909(
        File::Spec->catfile('.', 'tools', 'security_audit.pl')
    );

    $assert->like(
        $external,
        qr/exists\s+\$opts\{verify_SSL\}.*?:\s*1\s*;/s,
        'mb696-909: source contract keeps verify_SSL=1 as default'
    );

    $assert->like(
        $news,
        qr/my\s+\$http\s*=\s*
           Mediabot::External::_make_http\s*
           \(.*?verify_SSL\s*=>\s*1.*?\);/sx,
        'mb696-909: Tavily client explicitly verifies TLS'
    );

    $assert->like(
        $helpers,
        qr/HTTP::Tiny->new\(
           timeout\s*=>\s*3,\s*
           verify_SSL\s*=>\s*1
           \)->get\(\$whereis_url\)/x,
        'mb696-909: country.is direct HTTPS lookup verifies TLS'
    );

    my @admin_zero =
        ($admin =~ /verify_SSL\s*=>\s*0/g);

    $assert->is(
        scalar(@admin_zero),
        1,
        'mb696-909: AdminCommands has one reviewed explicit TLS opt-out'
    );

    $assert->like(
        $admin,
        qr/_radio_icecast_client.*?
           _make_http\([^\n]*verify_SSL\s*=>\s*0/sx,
        'mb696-909: reviewed opt-out belongs to Icecast client'
    );

    (my $external_code = $external)
        =~ s/^\s*#.*$//mg;

    $assert->unlike(
        $external_code,
        qr/\?\s*\$opts\{verify_SSL\}\s*:\s*0\s*;/,
        'mb696-909: insecure shared default cannot return silently'
    );

    $assert->like(
        $audit,
        qr/TLS verification secure by default/,
        'mb696-909: security audit enforces secure TLS default'
    );

    $assert->like(
        $audit,
        qr/unexpected explicit verify_SSL=>0 call/,
        'mb696-909: security audit rejects unreviewed TLS bypasses'
    );
};
