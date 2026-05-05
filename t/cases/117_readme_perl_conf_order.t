# t/cases/117_readme_perl_conf_order.t
# =============================================================================
# Regression checks for README Mediabot startup command syntax.
#
# --conf is a Mediabot argument, not a perl interpreter option.
# Correct:
#   perl mediabot.pl --conf=mediabot.conf
#
# Wrong:
#   perl --conf=mediabot.conf mediabot.pl
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
        'README does not pass --conf as a perl interpreter option'
    );

    $assert->like(
        $readme,
        qr/perl\s+mediabot\.pl\s+--conf=mediabot\.conf/,
        'README documents correct foreground start command order'
    );

    $assert->like(
        $readme,
        qr/perl\s+mediabot\.pl\s+--conf=mediabot\.conf\s+--daemon/,
        'README documents correct daemon start command order'
    );
};
