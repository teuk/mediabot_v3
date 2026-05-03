# t/cases/36_nicklist_pagination.t
# =============================================================================
# Static regression checks for nicklist paginated output.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_nicklist_pagination {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_nicklist_pagination {
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

    my $src  = _slurp_nicklist_pagination(File::Spec->catfile('.', 'Mediabot', 'ChannelCommands.pm'));
    my $func = _extract_sub_nicklist_pagination($src, 'channelNickList_ctx');

    $assert->ok(
        $func =~ /Users on \$target_chan: \$count result\(s\)/,
        'nicklist has summary line'
    );

    $assert->ok(
        $func =~ /my \$per_line = 10;/,
        'nicklist paginates at 10 nicks per line'
    );

    $assert->ok(
        $func =~ /nicklist\[%02d\]/,
        'nicklist detail lines are numbered'
    );

    $assert->ok(
        $func =~ /botNotice\(\$self, \$nick, \$line\);/,
        'nicklist sends paginated details by notice'
    );

    $assert->ok(
        $func =~ /Nicklist for \$target_chan is empty\./,
        'nicklist keeps empty-list message'
    );

    $assert->ok(
        $func !~ /my \$header = "Users on \$target_chan/,
        'nicklist no longer repeats a huge header per output line'
    );

    $assert->ok(
        $func !~ /my \$maxlen = 380/,
        'nicklist no longer uses old maxlen chunking'
    );
};
