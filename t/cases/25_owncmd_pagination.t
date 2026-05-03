# t/cases/25_owncmd_pagination.t
# =============================================================================
# Static regression checks for owncmd paginated output.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_owncmd_pagination {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_owncmd_pagination {
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

    my $src  = _slurp_owncmd_pagination(File::Spec->catfile('.', 'Mediabot', 'DBCommands.pm'));
    my $func = _extract_sub_owncmd_pagination($src, 'mbDbOwnersCommand_ctx');

    $assert->ok(
        $func =~ /sub mbDbOwnersCommand_ctx/,
        'owncmd function exists'
    );

    $assert->ok(
        $func =~ /LIMIT 50/,
        'owncmd limits output query to 50 owners'
    );

    $assert->ok(
        $func =~ /Command owners: \$count result\(s\), showing max 50/,
        'owncmd has summary line'
    );

    $assert->ok(
        $func =~ /details sent by notice to \$nick/,
        'owncmd avoids multi-line channel flood'
    );

    $assert->ok(
        $func =~ /my \$per_line = 5;/,
        'owncmd paginates at 5 owners per line'
    );

    $assert->ok(
        $func =~ /owncmd\[%02d\]/,
        'owncmd detail lines are numbered'
    );

    $assert->ok(
        $func =~ /botNotice\(\$self, \$nick, \$line\);/,
        'owncmd sends paginated details by notice'
    );

    $assert->ok(
        $func !~ /my \$max_len = 360/,
        'owncmd no longer uses old max_len single-line truncation'
    );

    $assert->ok(
        $func !~ /\$msg = \$prefix/,
        'owncmd no longer builds one huge prefix line'
    );
};
