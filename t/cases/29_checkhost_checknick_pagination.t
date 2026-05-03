# t/cases/29_checkhost_checknick_pagination.t
# =============================================================================
# Static regression checks for checkhost/checknick paginated output.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_checkhost_checknick {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_checkhost_checknick {
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

    my $src = _slurp_checkhost_checknick(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));

    my $checknick = _extract_sub_checkhost_checknick($src, 'mbDbCheckNickHostname_ctx');
    my $checkhost = _extract_sub_checkhost_checknick($src, 'mbDbCheckHostnameNick_ctx');

    $assert->ok(
        $checknick =~ /Hostmasks for \$search: \$count result\(s\), showing max 10/,
        'checknick has summary line'
    );

    $assert->ok(
        $checknick =~ /my \$per_line = 5;/,
        'checknick paginates at 5 entries per line'
    );

    $assert->ok(
        $checknick =~ /checknick\[%02d\]/,
        'checknick detail lines are numbered'
    );

    $assert->ok(
        $checknick =~ /details sent by notice to \$nick/,
        'checknick avoids multi-line channel flood'
    );

    $assert->ok(
        $checknick =~ /botNotice\(\$self, \$nick, \$line\);/,
        'checknick sends paginated details by notice'
    );

    $assert->ok(
        $checknick !~ /Hostmasks for \$search: \$list/,
        'checknick no longer builds one huge list line'
    );

    $assert->ok(
        $checkhost =~ /Nicks for host \$host: \$count result\(s\), showing max 20/,
        'checkhost has summary line'
    );

    $assert->ok(
        $checkhost =~ /my \$per_line = 5;/,
        'checkhost paginates at 5 entries per line'
    );

    $assert->ok(
        $checkhost =~ /checkhost\[%02d\]/,
        'checkhost detail lines are numbered'
    );

    $assert->ok(
        $checkhost =~ /details sent by notice to \$nick/,
        'checkhost avoids multi-line channel flood'
    );

    $assert->ok(
        $checkhost =~ /botNotice\(\$self, \$nick, \$line\);/,
        'checkhost sends paginated details by notice'
    );

    $assert->ok(
        $checkhost !~ /Nicks for host \$host: \$list/,
        'checkhost no longer builds one huge list line'
    );
};
