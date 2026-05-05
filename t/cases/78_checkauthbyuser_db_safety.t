# t/cases/78_checkauthbyuser_db_safety.t
# =============================================================================
# Static regression checks for LoginCommands::checkAuthByUser DB safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_checkauthbyuser_safety {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_checkauthbyuser {
    my ($src) = @_;

    my $start = index($src, "sub checkAuthByUser");
    die "sub checkAuthByUser not found" if $start < 0;

    my $next = index($src, "\n# Context-based cstat: one-line output, truncated with \"...\"\nsub userWhoAmI_ctx", $start);
    die "next marker after checkAuthByUser not found" if $next < 0;

    return substr($src, $start, $next - $start);
}

return sub {
    my ($assert) = @_;

    my $src  = _slurp_checkauthbyuser_safety(File::Spec->catfile('.', 'Mediabot', 'LoginCommands.pm'));
    my $func = _extract_checkauthbyuser($src);

    my $count = () = $src =~ /^sub\s+checkAuthByUser\s*\{/mg;
    $assert->ok(
        $count == 1,
        'there is exactly one checkAuthByUser sub'
    );

    $assert->ok(
        $func =~ /unless \(\$dbh\)/,
        'checkAuthByUser checks DB handle'
    );

    $assert->ok(
        $func =~ /make_password_hash failed/,
        'checkAuthByUser keeps hash failure handling'
    );

    $assert->ok(
        $func =~ /SELECT id_user FROM USER WHERE nickname = \? AND password = \?/,
        'checkAuthByUser keeps exact user/password lookup'
    );

    $assert->ok(
        $func =~ /unless \(\$sth\)/,
        'checkAuthByUser handles main prepare failure'
    );

    $assert->ok(
        $func =~ /checkAuthByUser\(\) SQL prepare error/,
        'checkAuthByUser logs main prepare failure'
    );

    $assert->ok(
        $func =~ /unless \(\$sth->execute\(\$sUserHandle, \$sHashedPw\)\)/,
        'checkAuthByUser handles main execute failure'
    );

    $assert->ok(
        $func =~ /\$sth->finish;\s*return \(0, 0\);/s,
        'checkAuthByUser finishes main statement on execute failure'
    );

    $assert->ok(
        $func =~ /SELECT id_user_hostmask FROM USER_HOSTMASK WHERE id_user=\? AND hostmask=\? LIMIT 1/,
        'checkAuthByUser keeps hostmask duplicate lookup'
    );

    $assert->ok(
        $func =~ /hostmask SQL prepare error/,
        'checkAuthByUser handles hostmask prepare failure'
    );

    $assert->ok(
        $func =~ /hostmask SQL execute error/,
        'checkAuthByUser handles hostmask execute failure'
    );

    $assert->ok(
        $func =~ /\$chk->finish;\s*return \(0, 0\);/s,
        'checkAuthByUser finishes hostmask statement on execute failure'
    );

    $assert->ok(
        $func =~ /INSERT INTO USER_HOSTMASK \(id_user, hostmask\) VALUES \(\?, \?\)/,
        'checkAuthByUser keeps hostmask insert'
    );

    $assert->ok(
        $func =~ /insert hostmask SQL prepare error/,
        'checkAuthByUser handles insert prepare failure'
    );

    $assert->ok(
        $func =~ /insert hostmask SQL execute error/,
        'checkAuthByUser handles insert execute failure'
    );

    $assert->ok(
        $func =~ /\$ins->finish;\s*return \(0, 0\);/s,
        'checkAuthByUser finishes insert statement on execute failure'
    );

    $assert->ok(
        $func =~ /return \(\$id_user, 1\);/,
        'checkAuthByUser still returns already-existing hostmask flag'
    );

    $assert->ok(
        $func =~ /return \(\$id_user, 0\);/,
        'checkAuthByUser still returns newly-added hostmask flag'
    );

    $assert->ok(
        $func !~ /\$chk->execute\(\$id_user, \$sHostmask\);\s*if \(\$chk->fetchrow_arrayref\)/s,
        'checkAuthByUser no longer has unchecked hostmask execute path'
    );
};
