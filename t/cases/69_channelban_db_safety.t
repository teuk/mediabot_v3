# t/cases/69_channelban_db_safety.t
# =============================================================================
# Static regression checks for Mediabot::ChannelBan DB safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_channelban_safety {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_channelban_safety {
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

    my $src = _slurp_channelban_safety(File::Spec->catfile('.', 'Mediabot', 'ChannelBan.pm'));

    $assert->ok(
        $src =~ /sub _log/,
        'ChannelBan has _log helper'
    );

    for my $subname (qw(active_ban_for_mask add_ban list_active_bans mark_removed expired_bans)) {
        my $func = _extract_sub_channelban_safety($src, $subname);

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
            "$subname finishes statement before returning on execute failure"
        );
    }

    my $add = _extract_sub_channelban_safety($src, 'add_ban');
    $assert->ok(
        $add =~ /last_insert_id/,
        'add_ban uses DBI last_insert_id after successful insert'
    );

    $assert->ok(
        $add =~ /mysql_insertid/,
        'add_ban keeps mysql_insertid fallback'
    );

    my $mark = _extract_sub_channelban_safety($src, 'mark_removed');
    $assert->ok(
        $mark =~ /return \(0, "database prepare error"\)/,
        'mark_removed returns explicit prepare error'
    );

    $assert->ok(
        $mark =~ /return \(0, "database execute error"\)/,
        'mark_removed returns explicit execute error'
    );

    my $active = _extract_sub_channelban_safety($src, 'active_ban_for_mask');
    $assert->ok(
        $active =~ /return undef unless defined\(\$id_channel\)/,
        'active_ban_for_mask validates channel id input'
    );

    $assert->ok(
        $active =~ /return undef unless defined\(\$hostmask\)/,
        'active_ban_for_mask validates hostmask input'
    );
};
