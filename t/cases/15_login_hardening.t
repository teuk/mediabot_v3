# t/cases/15_login_hardening.t
# =============================================================================
# Static regression checks for LoginCommands hardening.
#
# Protects:
#   - make_password_hash must be eval-protected
#   - unknown-user login failures must increment both IRC nick and typed DB user
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp(File::Spec->catfile('.', 'Mediabot', 'LoginCommands.pm'));

    $assert->ok(
        $src =~ /my \$hash_ok = eval \{/,
        'LoginCommands: password hash computation is eval-protected'
    );

    $assert->ok(
        $src =~ /\$calc_hash = make_password_hash\(\$typed_pass\);/,
        'LoginCommands: make_password_hash still computes typed password hash'
    );

    $assert->ok(
        $src =~ /password hash computation failed/,
        'LoginCommands: hash computation failure is logged'
    );

    $assert->ok(
        $src =~ /for my \$k \(lc\(\$sNick\), lc\(\$typed_user\)\)/,
        'LoginCommands: unknown-user path increments both IRC nick and typed user'
    );

    $assert->ok(
        $src =~ /Failed login \(Unknown user: \$typed_user\)/,
        'LoginCommands: unknown-user login still logs typed username context'
    );

    $assert->ok(
        $src =~ /delete \$self->\{_login_failures\}\{lc\(\$typed_user\)\}/,
        'LoginCommands: successful login resets typed-user failure counter'
    );
};
