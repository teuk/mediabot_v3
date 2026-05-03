# t/cases/33_quote_search_like_escape.t
# =============================================================================
# Static regression checks for quote search SQL LIKE escaping.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_quote_search_like_escape {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_quote_search_like_escape {
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

    my $src  = _slurp_quote_search_like_escape(File::Spec->catfile('.', 'Mediabot', 'Quotes.pm'));
    my $func = _extract_sub_quote_search_like_escape($src, 'mbQuoteSearch');

    $assert->ok(
        $func =~ /q\.quotetext LIKE \? ESCAPE '!'/,
        q{quote search uses MariaDB-safe ESCAPE '!'}
    );

    $assert->ok(
        $func =~ /\$w =~ s\/!\/!!\/g/,
        'quote search escapes the LIKE escape character itself'
    );

    $assert->ok(
        $func =~ /\$w =~ s\/%\/!%\/g/,
        'quote search escapes percent wildcard literally'
    );

    $assert->ok(
        $func =~ /\$w =~ s\/_\/!_\/g/,
        'quote search escapes underscore wildcard literally'
    );

    $assert->ok(
        $func =~ /my \@binds_words = map \{ "%\$_%" \} \@like_words/,
        'quote search still wraps each escaped word with SQL wildcards'
    );

    $assert->ok(
        $func =~ /join\(' AND ', map/,
        'quote search still uses AND logic for multi-word search'
    );

    $assert->ok(
        $func !~ /ESCAPE '\\\\'/,
        q{quote search no longer uses fragile ESCAPE '\'}
    );

    $assert->ok(
        $func !~ /\/\$sQuoteText\/i/,
        'quote search does not use direct user regex'
    );
};
