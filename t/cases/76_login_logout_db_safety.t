# t/cases/76_login_logout_db_safety.t
# =============================================================================
# Static regression checks for login/logout DB safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_login_logout_safety {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_between_login_logout {
    my ($src, $start_marker, $next_marker) = @_;

    my $start = index($src, $start_marker);
    die "start marker not found: $start_marker" if $start < 0;

    my $next = index($src, $next_marker, $start + length($start_marker));
    die "next marker not found after $start_marker" if $next < 0;

    return substr($src, $start, $next - $start);
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_login_logout_safety(File::Spec->catfile('.', 'Mediabot', 'LoginCommands.pm'));

    my $login = _extract_between_login_logout(
        $src,
        "sub userLogin_ctx {",
        "\n# Context-based logout command\nsub userLogout_ctx {",
    );

    my $logout = _extract_between_login_logout(
        $src,
        "# Context-based logout command\nsub userLogout_ctx {",
        "\n# check user Level\nsub mbRegister_ctx {",
    );

    $assert->ok(
        $login =~ /my \$run_select_one = sub/,
        'login has local select helper'
    );

    $assert->ok(
        $login =~ /my \$run_update = sub/,
        'login has local update helper'
    );

    $assert->ok(
        $login =~ /userLogin_ctx\(\) SQL prepare error/,
        'login logs select prepare failure'
    );

    $assert->ok(
        $login =~ /userLogin_ctx\(\) SQL execute error/,
        'login logs select execute failure'
    );

    $assert->ok(
        $login =~ /userLogin_ctx\(\) update SQL prepare error/,
        'login logs update prepare failure'
    );

    $assert->ok(
        $login =~ /userLogin_ctx\(\) update SQL execute error/,
        'login logs update execute failure'
    );

    $assert->ok(
        $login =~ /\$sth->finish;\s*return \(undef, "execute"\);/s,
        'login select helper finishes statement on execute failure'
    );

    $assert->ok(
        $login =~ /\$sth->finish;\s*return \(0, "execute"\);/s,
        'login update helper finishes statement on execute failure'
    );

    $assert->ok(
        $login =~ /UPDATE USER SET auth=1, last_login=NOW\(\) WHERE id_user=\?/,
        'login keeps auth success update'
    );

    $assert->ok(
        $login =~ /INSERT INTO USER_HOSTMASK \(id_user, hostmask\) VALUES \(\?, \?\)/,
        'login keeps hostmask registration insert'
    );

    $assert->ok(
        $login !~ /\$dbh->do\(/,
        'login no longer uses dbh->do'
    );

    $assert->ok(
        $login !~ /eval\s*\{\s*my \$sth = \$dbh->prepare/s,
        'login no longer wraps unchecked prepare/execute in eval'
    );

    $assert->ok(
        $logout =~ /unless \(\$dbh\)/,
        'logout checks DB handle'
    );

    $assert->ok(
        $logout =~ /unless \(\$sth\)/,
        'logout handles prepare failure'
    );

    $assert->ok(
        $logout =~ /userLogout_ctx\(\) SQL prepare error/,
        'logout logs prepare failure'
    );

    $assert->ok(
        $logout =~ /unless \(\$sth->execute\(\$uid\)\)/,
        'logout handles execute failure'
    );

    $assert->ok(
        $logout =~ /\$sth->finish;\s*botNotice\(\$self, \$nick, "Internal error during logout\."\);/s,
        'logout finishes statement on execute failure'
    );

    $assert->ok(
        $logout !~ /\$self->\{dbh\}->do/,
        'logout no longer uses dbh->do'
    );
};
