# t/cases/49_mp3_like_escape.t
# =============================================================================
# Static regression checks for mp3 SQL LIKE escaping.
#
# mp3 search intentionally keeps multi-token LIKE matching, but user-supplied
# %, _ and ! must be treated literally.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_mp3_like_escape {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_mp3_like_escape {
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

    my $src  = _slurp_mp3_like_escape(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));
    my $func = _extract_sub_mp3_like_escape($src, 'mp3_ctx');

    $assert->ok(
        $func =~ /my \@safe_tokens = map/,
        'mp3 search builds escaped token list'
    );

    $assert->ok(
        $func =~ /\$t =~ s\/!\/!!\/g/,
        'mp3 search escapes LIKE escape character'
    );

    $assert->ok(
        $func =~ /\$t =~ s\/%\/!%\/g/,
        'mp3 search escapes percent wildcard literally'
    );

    $assert->ok(
        $func =~ /\$t =~ s\/_\/!_\/g/,
        'mp3 search escapes underscore wildcard literally'
    );

    $assert->ok(
        $func =~ /my \$pattern = '%' \. join\('%', \@safe_tokens\) \. '%'/,
        'mp3 search keeps ordered multi-token LIKE pattern'
    );

    my $escaped_like_count = () = $func =~ /CONCAT\(artist, ' ', title\) LIKE \? ESCAPE '!'/g;
    $assert->ok(
        $escaped_like_count >= 3,
        'mp3 count/first/list queries use MariaDB-safe ESCAPE'
    );

    $assert->ok(
        $func !~ /CONCAT\(artist, ' ', title\) LIKE \?(?! ESCAPE '!')/,
        'mp3 has no unescaped title LIKE query left'
    );
};
