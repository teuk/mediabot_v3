# t/cases/79_quotes_db_safety.t
# =============================================================================
# Static regression checks for Mediabot::Quotes DB safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_quotes_safety {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_quotes_safety {
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

    my $src = _slurp_quotes_safety(File::Spec->catfile('.', 'Mediabot', 'Quotes.pm'));

    for my $subname (qw(mbQuoteAdd mbQuoteDel mbQuoteView mbQuoteSearch mbQuoteRand mbQuoteStats)) {
        my $func = _extract_sub_quotes_safety($src, $subname);

        $assert->ok(
            $func =~ /unless \(\$sth/,
            "$subname handles prepare failure"
        );

        $assert->ok(
            $func =~ /prepare error/,
            "$subname logs prepare failure"
        );

        $assert->ok(
            $func =~ /execute error/,
            "$subname logs execute failure"
        );

        $assert->ok(
            $func =~ /finish;/,
            "$subname finishes statement handles"
        );
    }

    my $add = _extract_sub_quotes_safety($src, 'mbQuoteAdd');
    $assert->ok(
        $add =~ /\$self->\{dbh\}->last_insert_id/,
        'mbQuoteAdd uses DB handle last_insert_id'
    );

    $assert->ok(
        $add =~ /mysql_insertid/,
        'mbQuoteAdd keeps mysql_insertid fallback'
    );

    $assert->ok(
        $add =~ /\$self->\{channels\}\{\$sChannel\} \|\| \$self->\{channels\}\{lc\(\$sChannel\)\}/,
        'mbQuoteAdd supports case-insensitive channel object lookup'
    );

    my $del = _extract_sub_quotes_safety($src, 'mbQuoteDel');
    $assert->ok(
        $del =~ /\$id_quotes =~ \/\^\\d\+\$\//,
        'mbQuoteDel validates numeric ID strictly'
    );

    my $view = _extract_sub_quotes_safety($src, 'mbQuoteView');
    $assert->ok(
        $view =~ /\$id_quotes =~ \/\^\\d\+\$\//,
        'mbQuoteView validates numeric ID strictly'
    );

    my $search = _extract_sub_quotes_safety($src, 'mbQuoteSearch');
    $assert->ok(
        $search =~ /LIKE \? ESCAPE '!'/,
        'mbQuoteSearch keeps MariaDB-safe LIKE escaping'
    );

    my $rand = _extract_sub_quotes_safety($src, 'mbQuoteRand');
    $assert->ok(
        $rand =~ /COUNT\(\*\)/,
        'mbQuoteRand keeps count/offset random strategy'
    );

    $assert->ok(
        $src !~ /unless \(\$sth && \$sth->execute/,
        'Quotes.pm no longer uses combined prepare/execute guard'
    );
};
