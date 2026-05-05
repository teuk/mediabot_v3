# t/cases/110_conn_bind_ip_config_defaults.t
# =============================================================================
# Regression checks for connection.CONN_BIND_IP.
#
# CONN_BIND_IP is optional. The runtime reads it, but default/sample configs
# must not actively set a documentation placeholder such as 192.0.2.42.
#
# A copied sample should not make the bot bind a non-local source IP.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_conn_bind_ip_defaults {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _section_body_conn_bind_ip_defaults {
    my ($src, $section) = @_;

    my ($body) = $src =~ /^\[\Q$section\E\]\s*\n(.*?)(?=^\[[^\]]+\]\s*$|\z)/ms;
    return $body;
}

return sub {
    my ($assert) = @_;

    my $sample = _slurp_conn_bind_ip_defaults(
        File::Spec->catfile('.', 'mediabot.sample.conf')
    );

    my $live = _slurp_conn_bind_ip_defaults(
        File::Spec->catfile('.', 't', 'live', 'test.conf.tpl')
    );

    my $main = _slurp_conn_bind_ip_defaults(
        File::Spec->catfile('.', 'mediabot.pl')
    );

    my $sample_connection = _section_body_conn_bind_ip_defaults($sample, 'connection');
    my $live_connection   = _section_body_conn_bind_ip_defaults($live,   'connection');

    $assert->ok(
        defined $sample_connection,
        'sample config has a [connection] section'
    );

    $assert->ok(
        defined $live_connection,
        'live template has a [connection] section'
    );

    $assert->like(
        $main,
        qr/get\('connection\.CONN_BIND_IP'\)/,
        'mediabot.pl reads connection.CONN_BIND_IP'
    );

    $assert->like(
        $sample_connection // '',
        qr/^CONN_BIND_IP=$/m,
        'sample config defines CONN_BIND_IP as empty by default'
    );

    $assert->like(
        $sample_connection // '',
        qr/^#CONN_BIND_IP=192\.0\.2\.42$/m,
        'sample config keeps placeholder bind IP only as a commented example'
    );

    $assert->unlike(
        $sample_connection // '',
        qr/^CONN_BIND_IP=192\.0\.2\.42$/m,
        'sample config does not actively bind the documentation placeholder IP'
    );

    $assert->like(
        $live_connection // '',
        qr/^CONN_BIND_IP=$/m,
        'live template defines empty CONN_BIND_IP'
    );

    $assert->unlike(
        $live_connection // '',
        qr/^CONN_BIND_IP=192\.0\.2\.42$/m,
        'live template does not bind a documentation placeholder IP'
    );
};
