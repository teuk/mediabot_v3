# t/cases/62_usercommands_onjoin_logout_db_safety.t
# =============================================================================
# Static regression checks for dbLogoutUsers/userOnJoin DB safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_onjoin_logout_safety {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_onjoin_logout_safety {
    my ($src, $name) = @_;

    my $start = index($src, "sub $name");
    die "sub $name not found" if $start < 0;

    my $brace = index($src, "{", $start);
    die "opening brace for $name not found" if $brace < 0;

    my $depth      = 0;
    my $in_single  = 0;
    my $in_double  = 0;
    my $in_comment = 0;
    my $escape     = 0;

    for (my $i = $brace; $i < length($src); $i++) {
        my $c = substr($src, $i, 1);

        if ($in_comment) {
            $in_comment = 0 if $c eq "\n";
            next;
        }

        if ($in_single) {
            if ($c eq "\\" && !$escape) {
                $escape = 1;
                next;
            }

            if ($c eq "'" && !$escape) {
                $in_single = 0;
            }

            $escape = 0;
            next;
        }

        if ($in_double) {
            if ($c eq "\\" && !$escape) {
                $escape = 1;
                next;
            }

            if ($c eq '"' && !$escape) {
                $in_double = 0;
            }

            $escape = 0;
            next;
        }

        if ($c eq "#") {
            $in_comment = 1;
            next;
        }

        if ($c eq "'") {
            $in_single = 1;
            next;
        }

        if ($c eq '"') {
            $in_double = 1;
            next;
        }

        if ($c eq "{") {
            $depth++;
        }
        elsif ($c eq "}") {
            $depth--;

            if ($depth == 0) {
                return substr($src, $start, $i - $start + 1);
            }
        }
    }

    die "end of sub $name not found";
}

return sub {
    my ($assert) = @_;

    my $src    = _slurp_onjoin_logout_safety(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my $logout = _extract_sub_onjoin_logout_safety($src, 'dbLogoutUsers');
    my $join   = _extract_sub_onjoin_logout_safety($src, 'userOnJoin');

    $assert->ok(
        $logout =~ /unless \(\$dbh\)/,
        'dbLogoutUsers handles missing DB handle'
    );

    $assert->ok(
        $logout =~ /unless \(\$sth\)/,
        'dbLogoutUsers handles prepare failure'
    );

    $assert->ok(
        $logout =~ /dbLogoutUsers\(\) SQL prepare error/,
        'dbLogoutUsers logs prepare failure'
    );

    $assert->ok(
        $logout =~ /unless \(\$sth->execute\(\)\)/,
        'dbLogoutUsers handles execute failure'
    );

    $assert->ok(
        $logout =~ /\$sth->finish;\s*return 0;/s,
        'dbLogoutUsers finishes statement on execute failure'
    );

    $assert->ok(
        $logout =~ /\$sth->finish;\s*\$self->\{logger\}->log/s,
        'dbLogoutUsers finishes statement on success'
    );

    $assert->ok(
        $join =~ /userOnJoin\(\) SQL prepare error/,
        'userOnJoin handles user-channel prepare failure'
    );

    $assert->ok(
        $join =~ /userOnJoin\(\) SQL execute error/,
        'userOnJoin handles user-channel execute failure'
    );

    $assert->ok(
        $join =~ /userOnJoin\(\) channel SQL prepare error/,
        'userOnJoin handles channel-notice prepare failure'
    );

    $assert->ok(
        $join =~ /userOnJoin\(\) channel SQL execute error/,
        'userOnJoin handles channel-notice execute failure'
    );

    $assert->ok(
        $join =~ /\$sth->finish;\s*\}/s,
        'userOnJoin finishes statements in successful paths'
    );

    $assert->ok(
        $join =~ /SELECT id_channel, notice FROM CHANNEL WHERE name = \?/,
        'userOnJoin keeps exact channel notice lookup'
    );
};
