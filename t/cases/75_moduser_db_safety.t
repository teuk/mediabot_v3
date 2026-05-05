# t/cases/75_moduser_db_safety.t
# =============================================================================
# Static regression checks for mbModUser_ctx DB safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_moduser_safety {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_moduser_safety {
    my ($src, $name) = @_;

    my $start = index($src, "sub $name");
    die "sub $name not found" if $start < 0;

    my $next = index($src, "\n# Helper: print moduser usage\nsub _sendModUserSyntax", $start);
    die "next marker after $name not found" if $next < 0;

    return substr($src, $start, $next - $start);
}

return sub {
    my ($assert) = @_;

    my $src  = _slurp_moduser_safety(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my $func = _extract_sub_moduser_safety($src, 'mbModUser_ctx');

    $assert->ok(
        $func =~ /my \$select_one = sub/,
        'moduser has local select helper'
    );

    $assert->ok(
        $func =~ /my \$run_update = sub/,
        'moduser has local update helper'
    );

    $assert->ok(
        $func =~ /mbModUser_ctx\(\) SQL prepare error/,
        'moduser select helper logs prepare failure'
    );

    $assert->ok(
        $func =~ /mbModUser_ctx\(\) SQL execute error/,
        'moduser select helper logs execute failure'
    );

    $assert->ok(
        $func =~ /mbModUser_ctx\(\) update SQL prepare error/,
        'moduser update helper logs prepare failure'
    );

    $assert->ok(
        $func =~ /mbModUser_ctx\(\) update SQL execute error/,
        'moduser update helper logs execute failure'
    );

    $assert->ok(
        $func =~ /\$sth->finish;\s*return \(undef, "execute"\);/s,
        'moduser select helper finishes statement on execute failure'
    );

    $assert->ok(
        $func =~ /\$sth->finish;\s*return \(0, "execute"\);/s,
        'moduser update helper finishes statement on execute failure'
    );

    $assert->ok(
        $func =~ /SELECT 1 FROM USER WHERE nickname = \? AND username = '#AUTOLOGIN#'/,
        'moduser keeps autologin status lookup'
    );

    $assert->ok(
        $func =~ /UPDATE USER SET username = '#AUTOLOGIN#' WHERE nickname = \?/,
        'moduser keeps autologin enable update'
    );

    $assert->ok(
        $func =~ /UPDATE USER SET username = NULL WHERE nickname = \?/,
        'moduser keeps autologin disable update'
    );

    $assert->ok(
        $func =~ /SELECT 1 FROM USER WHERE nickname = \? AND fortniteid = \?/,
        'moduser keeps fortniteid duplicate lookup'
    );

    $assert->ok(
        $func =~ /UPDATE USER SET fortniteid = \? WHERE nickname = \?/,
        'moduser keeps fortniteid update'
    );

    $assert->ok(
        $func !~ /\$sth->execute\(\$target_nick\);\s*my \$already_on/s,
        'moduser no longer has unchecked autologin execute path'
    );

    $assert->ok(
        $func !~ /\$sth->execute\(\$target_nick, \$fortniteid\);\s*my \$already_set/s,
        'moduser no longer has unchecked fortniteid execute path'
    );
};
