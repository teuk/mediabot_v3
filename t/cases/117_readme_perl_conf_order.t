# t/cases/117_readme_perl_conf_order.t
# =============================================================================
# Regression checks for the supported first-start workflow.
#
# --conf belongs after mediabot.pl. README deliberately starts in foreground
# and tells operators not to daemonize until startup is clean.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_readme_perl_conf_order {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $readme = _slurp_readme_perl_conf_order(
        File::Spec->catfile('.', 'README.md')
    );

    $assert->unlike(
        $readme,
        qr/perl\s+--conf=mediabot\.conf\s+mediabot\.pl/,
        'README does not pass --conf as a Perl interpreter option'
    );
    $assert->unlike(
        $readme,
        qr/^\.\/start$/m,
        'README no longer recommends the removed ./start wrapper (mb447)'
    );
    $assert->like(
        $readme,
        qr/^perl\s+mediabot\.pl\s+--conf=mediabot\.conf$/m,
        'README documents correct explicit foreground command order'
    );
    $assert->like(
        $readme,
        qr/Do not switch to systemd until foreground startup is clean\./,
        'README explicitly requires a clean foreground start before systemd (mb447)'
    );
};
