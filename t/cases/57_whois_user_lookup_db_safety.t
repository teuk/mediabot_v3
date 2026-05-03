# t/cases/57_whois_user_lookup_db_safety.t
# =============================================================================
# Static regression checks for WHOIS user lookup DB safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_whois_user_lookup_safety {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_whois_user_lookup_safety {
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

    my $src = _slurp_whois_user_lookup_safety(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));

    my $whois = _extract_sub_whois_user_lookup_safety($src, 'get_user_from_whois');
    my $nick  = _extract_sub_whois_user_lookup_safety($src, 'getNickInfoWhois');

    $assert->ok(
        $whois =~ /unless \(\$sth\)/,
        'get_user_from_whois handles main prepare failure'
    );

    $assert->ok(
        $whois =~ /get_user_from_whois\(\) SQL prepare error/,
        'get_user_from_whois logs main prepare failure'
    );

    $assert->ok(
        $whois =~ /unless \(\$sth->execute\)/,
        'get_user_from_whois handles main execute failure'
    );

    $assert->ok(
        $whois =~ /\$sth->finish;\s*return undef;/s,
        'get_user_from_whois finishes main statement on execute failure'
    );

    $assert->ok(
        $whois =~ /get_user_from_whois\(\) level SQL prepare error/,
        'get_user_from_whois handles level prepare failure'
    );

    $assert->ok(
        $whois =~ /get_user_from_whois\(\) level SQL execute error/,
        'get_user_from_whois handles level execute failure'
    );

    $assert->ok(
        $nick =~ /unless \(\$sth\)/,
        'getNickInfoWhois handles main prepare failure'
    );

    $assert->ok(
        $nick =~ /getNickInfoWhois\(\) SQL prepare error/,
        'getNickInfoWhois logs main prepare failure'
    );

    $assert->ok(
        $nick =~ /unless \(\$sth->execute\)/,
        'getNickInfoWhois handles main execute failure'
    );

    $assert->ok(
        $nick =~ /\$sth->finish;\s*return \(undef, undef, undef, undef, undef, undef, undef, undef\);/s,
        'getNickInfoWhois finishes main statement on execute failure'
    );

    $assert->ok(
        $nick =~ /getNickInfoWhois\(\) level SQL prepare error/,
        'getNickInfoWhois handles level prepare failure'
    );

    $assert->ok(
        $nick =~ /getNickInfoWhois\(\) level SQL execute error/,
        'getNickInfoWhois handles level execute failure'
    );
};
