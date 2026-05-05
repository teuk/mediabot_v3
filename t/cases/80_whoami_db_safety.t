# t/cases/80_whoami_db_safety.t
# =============================================================================
# Static regression checks for LoginCommands::userWhoAmI_ctx DB safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_whoami_safety {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_whoami {
    my ($src) = @_;

    my $start = index($src, "sub userWhoAmI_ctx");
    die "sub userWhoAmI_ctx not found" if $start < 0;

    my $next = index($src, "\n# Add a new public command to the database (Administrator+)\nsub userPass_ctx", $start);
    die "next marker after userWhoAmI_ctx not found" if $next < 0;

    return substr($src, $start, $next - $start);
}

return sub {
    my ($assert) = @_;

    my $src  = _slurp_whoami_safety(File::Spec->catfile('.', 'Mediabot', 'LoginCommands.pm'));
    my $func = _extract_whoami($src);

    my $count = () = $src =~ /^sub\s+userWhoAmI_ctx\s*\{/mg;
    $assert->ok(
        $count == 1,
        'there is exactly one userWhoAmI_ctx sub'
    );

    $assert->ok(
        $func =~ /unless \(\$dbh\)/,
        'userWhoAmI_ctx checks DB handle'
    );

    $assert->ok(
        $func =~ /SELECT username, password, creation_date, last_login, auth FROM USER WHERE id_user=\? LIMIT 1/,
        'userWhoAmI_ctx keeps main user details lookup'
    );

    $assert->ok(
        $func =~ /unless \(\$sth\)/,
        'userWhoAmI_ctx handles main prepare failure'
    );

    $assert->ok(
        $func =~ /userWhoAmI_ctx\(\) SQL prepare error/,
        'userWhoAmI_ctx logs main prepare failure'
    );

    $assert->ok(
        $func =~ /unless \(\$sth->execute\(\$uid\)\)/,
        'userWhoAmI_ctx handles main execute failure'
    );

    $assert->ok(
        $func =~ /\$sth->finish;\s*botNotice\(\$self, \$nick, "Internal error \(query failed\)\."\);/s,
        'userWhoAmI_ctx finishes main statement on execute failure'
    );

    $assert->ok(
        $func =~ /\$sth->finish;\s*unless \(\$ref\)/s,
        'userWhoAmI_ctx finishes main statement before row check'
    );

    $assert->ok(
        $func =~ /SELECT hostmask FROM USER_HOSTMASK WHERE id_user=\? ORDER BY id_user_hostmask LIMIT 20/,
        'userWhoAmI_ctx keeps hostmask lookup'
    );

    $assert->ok(
        $func =~ /hostmask SQL prepare error/,
        'userWhoAmI_ctx handles hostmask prepare failure'
    );

    $assert->ok(
        $func =~ /hostmask SQL execute error/,
        'userWhoAmI_ctx handles hostmask execute failure'
    );

    $assert->ok(
        $func =~ /\$hm_sth->finish;/,
        'userWhoAmI_ctx finishes hostmask statement'
    );

    $assert->ok(
        $func !~ /unless \(\$sth && \$sth->execute/,
        'userWhoAmI_ctx no longer uses combined main prepare/execute guard'
    );

    $assert->ok(
        $func !~ /if \(\$hm_sth2 && \$hm_sth2->execute/,
        'userWhoAmI_ctx no longer uses combined hostmask prepare/execute guard'
    );

    $assert->ok(
        $func =~ /whoami-masks\[%02d\]/,
        'userWhoAmI_ctx keeps paginated hostmask output'
    );
};
