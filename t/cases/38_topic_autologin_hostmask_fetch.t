# t/cases/38_topic_autologin_hostmask_fetch.t
# =============================================================================
# Static regression checks for topic autologin hostmask lookup.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_topic_autologin {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_topic_autologin {
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

    my $src  = _slurp_topic_autologin(File::Spec->catfile('.', 'Mediabot', 'ChannelCommands.pm'));
    my $func = _extract_sub_topic_autologin($src, 'userTopicChannel');

    $assert->ok(
        $func =~ /SELECT hostmask FROM USER_HOSTMASK WHERE id_user=\? ORDER BY id_user_hostmask/,
        'topic autologin fetches hostmasks row-by-row'
    );

    $assert->ok(
        $func =~ /while \(my \(\$mask\) = \$hm_sth->fetchrow_array\)/,
        'topic autologin iterates hostmask rows'
    );

    $assert->ok(
        $func =~ /push \@masks, \$mask/,
        'topic autologin stores hostmasks in an array'
    );

    $assert->ok(
        $func =~ /for my \$mask \(\@masks\)/,
        'topic autologin matches against array of hostmasks'
    );

    $assert->ok(
        $func =~ /userTopicChannel\(\) hostmask SQL Error/,
        'topic autologin logs hostmask SQL errors'
    );

    $assert->ok(
        $func !~ /GROUP_CONCAT\(hostmask/,
        'topic autologin no longer GROUP_CONCATs hostmasks'
    );

    $assert->ok(
        $func !~ /split \/,\/, \(\$masks/,
        'topic autologin no longer splits a comma-concatenated hostmask string'
    );
};
