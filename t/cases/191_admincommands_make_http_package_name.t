# t/cases/191_admincommands_make_http_package_name.t
# =============================================================================
# Regression checks for AdminCommands HTTP factory calls.
#
# The HTTP helper lives in Mediabot::External, not in a package named External.
# Calling External::_make_http would fail at runtime.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_191 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $admin = _slurp_191(
        File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm')
    );

    my $external = _slurp_191(
        File::Spec->catfile('.', 'Mediabot', 'External.pm')
    );

    $assert->like(
        $external,
        qr/sub _make_http/,
        'Mediabot::External defines _make_http'
    );

    $assert->like(
        $admin,
        qr/use Mediabot::External/,
        'AdminCommands explicitly loads Mediabot::External'
    );

    $assert->like(
        $admin,
        qr/Mediabot::External::_make_http/,
        'AdminCommands uses the correct Mediabot::External::_make_http package'
    );

    $assert->unlike(
        $admin,
        qr/(?<!Mediabot::)External::_make_http/,
        'AdminCommands no longer calls an unqualified External::_make_http package'
    );

    my $count = () = $admin =~ /Mediabot::External::_make_http/g;

    $assert->ok(
        $count >= 1,
        'AdminCommands still uses shared HTTP factory'
    );
};
