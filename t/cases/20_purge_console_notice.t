# t/cases/20_purge_console_notice.t
# =============================================================================
# Static regression checks for purge visibility.
#
# Background purges should be visible to operators when they actually delete
# rows, without spamming console when there is nothing to purge.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_purge_console_notice {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_purge_console_notice {
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

    my $src = _slurp_purge_console_notice(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));

    my $purge_log  = _extract_sub_purge_console_notice($src, 'purge_channel_log');
    my $purge_seen = _extract_sub_purge_console_notice($src, 'purge_user_seen');

    $assert->ok(
        $purge_log =~ /if \(\$rows\)/,
        'purge_channel_log only reports when rows were deleted'
    );

    $assert->ok(
        $purge_log =~ /noticeConsoleChan\(\$self, \$msg\)/,
        'purge_channel_log notifies console channel'
    );

    $assert->ok(
        $purge_log =~ /purge_channel_log: \$rows row\(s\) deleted/,
        'purge_channel_log message includes deleted row count'
    );

    $assert->ok(
        $purge_seen =~ /if \(\$rows\)/,
        'purge_user_seen only reports when rows were deleted'
    );

    $assert->ok(
        $purge_seen =~ /noticeConsoleChan\(\$self, \$msg\)/,
        'purge_user_seen notifies console channel'
    );

    $assert->ok(
        $purge_seen =~ /purge_user_seen: \$rows stale nick\(s\) purged/,
        'purge_user_seen message includes purged nick count'
    );
};
