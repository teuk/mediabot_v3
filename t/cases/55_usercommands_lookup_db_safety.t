# t/cases/55_usercommands_lookup_db_safety.t
# =============================================================================
# Static regression checks for UserCommands lookup helper DB safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_usercommands_lookup_safety {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_usercommands_lookup_safety {
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

    my $src = _slurp_usercommands_lookup_safety(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));

    for my $subname (qw(getLevelUser getUserLevelDesc getUserChannelLevel)) {
        my $func = _extract_sub_usercommands_lookup_safety($src, $subname);

        $assert->ok(
            $func =~ /unless \(\$sth\)/,
            "$subname handles prepare failure"
        );

        $assert->ok(
            $func =~ /SQL prepare error/,
            "$subname logs prepare failure"
        );

        $assert->ok(
            $func =~ /unless \(\$sth->execute/,
            "$subname handles execute failure"
        );

        $assert->ok(
            $func =~ /SQL execute error/,
            "$subname logs execute failure"
        );

        $assert->ok(
            $func =~ /\$sth->finish;\s*return/s,
            "$subname finishes statement before returning after execute failure"
        );

        $assert->ok(
            $func =~ /\$sth->finish;\s*return/s,
            "$subname finishes statement before final return"
        );
    }

    my $get_level = _extract_sub_usercommands_lookup_safety($src, 'getLevelUser');
    $assert->ok(
        $get_level =~ /WHERE USER\.nickname = \?/,
        'getLevelUser keeps exact nickname lookup'
    );

    my $desc = _extract_sub_usercommands_lookup_safety($src, 'getUserLevelDesc');
    $assert->ok(
        $desc =~ /WHERE level = \?/,
        'getUserLevelDesc keeps exact numeric level lookup'
    );

    my $chan = _extract_sub_usercommands_lookup_safety($src, 'getUserChannelLevel');
    $assert->ok(
        $chan =~ /WHERE CHANNEL\.name = \? AND USER_CHANNEL\.id_user = \?/,
        'getUserChannelLevel keeps exact channel/user lookup'
    );
};
