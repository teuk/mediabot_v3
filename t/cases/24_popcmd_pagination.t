# t/cases/24_popcmd_pagination.t
# =============================================================================
# Static regression checks for popcmd paginated output and MariaDB-safe LIKE.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_popcmd_pagination {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_popcmd_pagination {
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

    my $src  = _slurp_popcmd_pagination(File::Spec->catfile('.', 'Mediabot', 'DBCommands.pm'));
    my $func = _extract_sub_popcmd_pagination($src, 'mbPopCommand_ctx');

    $assert->ok(
        $func =~ /sub mbPopCommand_ctx/,
        'popcmd function exists'
    );

    $assert->ok(
        $func =~ /LIMIT 20/,
        'popcmd keeps SQL LIMIT 20'
    );

    $assert->ok(
        $func =~ /LIKE \? ESCAPE '!'/,
        q{popcmd uses MariaDB-safe SQL LIKE ESCAPE '!'}
    );

    $assert->ok(
        $func =~ /\$like =~ s\/!\/!!\/g/,
        'popcmd escapes the SQL LIKE escape character itself'
    );

    $assert->ok(
        $func =~ /\$like =~ s\/%\/!%\/g/,
        'popcmd escapes percent wildcard literally'
    );

    $assert->ok(
        $func =~ /\$like =~ s\/_\/!_\/g/,
        'popcmd escapes underscore wildcard literally'
    );

    $assert->ok(
        $func =~ /my \$per_line = 5;/,
        'popcmd paginates at 5 commands per line'
    );

    $assert->ok(
        $func =~ /popcmd\[%02d\]/,
        'popcmd detail lines are numbered'
    );

    $assert->ok(
        $func =~ /details sent by notice to \$nick/,
        'popcmd avoids multi-line channel flood'
    );

    $assert->ok(
        $func =~ /botNotice\(\$self, \$nick, \$line\);/,
        'popcmd sends paginated details by notice'
    );

    $assert->ok(
        $func !~ /ESCAPE '\\\\'/,
        q{popcmd no longer uses fragile ESCAPE '\'}
    );

    $assert->ok(
        $func !~ /my \$max_len = 360/,
        'popcmd no longer uses old max_len single-line truncation'
    );

    $assert->ok(
        $func !~ /\$line = \$prefix/,
        'popcmd no longer builds one huge prefix line'
    );
};
