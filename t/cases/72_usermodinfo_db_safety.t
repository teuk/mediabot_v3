# t/cases/72_usermodinfo_db_safety.t
# =============================================================================
# Static regression checks for userModinfo_ctx DB safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_usermodinfo_safety {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_usermodinfo_safety {
    my ($src, $name) = @_;

    my $start = index($src, "sub $name");
    die "sub $name not found" if $start < 0;

    my $next = index($src, "\n# Get user ID and level on a specific channel\nsub userTopSay_ctx", $start);
    die "next marker after $name not found" if $next < 0;

    return substr($src, $start, $next - $start);
}

return sub {
    my ($assert) = @_;

    my $src  = _slurp_usermodinfo_safety(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my $func = _extract_sub_usermodinfo_safety($src, 'userModinfo_ctx');

    $assert->ok(
        $func !~ /eval\s*\{\s*my \$sth_issuer/s,
        'userModinfo no longer wraps unchecked issuer/target DB lookups in eval'
    );

    $assert->ok(
        $func =~ /my \$fetch_channel_level = sub/,
        'userModinfo has local issuer level fetch helper'
    );

    $assert->ok(
        $func =~ /my \$fetch_target = sub/,
        'userModinfo has local target fetch helper'
    );

    $assert->ok(
        $func =~ /my \$run_update = sub/,
        'userModinfo has local update helper'
    );

    $assert->ok(
        $func =~ /issuer SQL prepare error/,
        'userModinfo handles issuer prepare failure'
    );

    $assert->ok(
        $func =~ /issuer SQL execute error/,
        'userModinfo handles issuer execute failure'
    );

    $assert->ok(
        $func =~ /target SQL prepare error/,
        'userModinfo handles target prepare failure'
    );

    $assert->ok(
        $func =~ /target SQL execute error/,
        'userModinfo handles target execute failure'
    );

    $assert->ok(
        $func =~ /update SQL prepare error/,
        'userModinfo handles update prepare failure'
    );

    $assert->ok(
        $func =~ /update SQL execute error/,
        'userModinfo handles update execute failure'
    );

    $assert->ok(
        $func =~ /\$sth->finish;\s*return \(undef, "execute"\);/s,
        'userModinfo finishes issuer statement on execute failure'
    );

    $assert->ok(
        $func =~ /\$sth->finish;\s*return \(undef, undef, "execute"\);/s,
        'userModinfo finishes target statement on execute failure'
    );

    $assert->ok(
        $func =~ /\$sth->finish;\s*return 0;/s,
        'userModinfo finishes update statement on execute failure'
    );

    $assert->ok(
        $func =~ /UPDATE USER_CHANNEL SET automode=\? WHERE id_user=\? AND id_channel=\?/,
        'userModinfo keeps automode update'
    );

    $assert->ok(
        $func =~ /UPDATE USER_CHANNEL SET greet=\? WHERE id_user=\? AND id_channel=\?/,
        'userModinfo keeps greet update'
    );

    $assert->ok(
        $func =~ /UPDATE USER_CHANNEL SET level=\? WHERE id_user=\? AND id_channel=\?/,
        'userModinfo keeps level update'
    );
};
