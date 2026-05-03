# t/cases/30_checkhostchan_pagination.t
# =============================================================================
# Static regression checks for checkhostchan paginated output.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_checkhostchan {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_checkhostchan {
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

    my $src = _slurp_checkhostchan(File::Spec->catfile('.', 'Mediabot', 'ChannelCommands.pm'));
    my $func = _extract_sub_checkhostchan($src, 'mbDbCheckHostnameNickChan_ctx');

    $assert->ok(
        $func =~ /Nicks for host \$hostname on \$target_chan: \$count result\(s\), showing max 20/,
        'checkhostchan has summary line'
    );

    $assert->ok(
        $func =~ /my \$per_line = 5;/,
        'checkhostchan paginates at 5 entries per line'
    );

    $assert->ok(
        $func =~ /checkhostchan\[%02d\]/,
        'checkhostchan detail lines are numbered'
    );

    $assert->ok(
        $func =~ /details sent by notice to \$nick/,
        'checkhostchan avoids multi-line channel flood'
    );

    $assert->ok(
        $func =~ /botNotice\(\$self, \$nick, \$line\);/,
        'checkhostchan sends paginated details by notice'
    );

    $assert->ok(
        $func !~ /Nicks for host \$hostname on \$target_chan: \$list/,
        'checkhostchan no longer builds one huge list line'
    );
};
