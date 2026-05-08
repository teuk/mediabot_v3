# t/cases/211_tmdb_logger_no_warn_regression.t
# =============================================================================
# Regression checks for TMDB logging.
#
# get_tmdb_info() should not write directly to STDERR with warn. When called
# from mbTMDBSearch_ctx(), it should receive the Mediabot logger and log errors
# through the normal bot logging path.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_211 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_211 {
    my ($src, $sub_name) = @_;

    my $re = qr/^[ \t]*sub[ \t]+\Q$sub_name\E\b[^{]*\{/m;
    return undef unless $src =~ /$re/g;

    my $start = $-[0];
    my $pos   = pos($src);
    my $depth = 1;
    my $len   = length($src);

    my $quote;
    my $escape  = 0;
    my $comment = 0;

    while ($pos < $len) {
        my $ch = substr($src, $pos, 1);

        if ($comment) {
            $comment = 0 if $ch eq "\n";
            $pos++;
            next;
        }

        if (defined $quote) {
            if ($escape) {
                $escape = 0;
                $pos++;
                next;
            }

            if ($ch eq "\\") {
                $escape = 1;
                $pos++;
                next;
            }

            if ($ch eq $quote) {
                undef $quote;
                $pos++;
                next;
            }

            $pos++;
            next;
        }

        if ($ch eq '#') {
            $comment = 1;
            $pos++;
            next;
        }

        if ($ch eq '"' || $ch eq "'") {
            $quote = $ch;
            $pos++;
            next;
        }

        if ($ch eq '{') {
            $depth++;
        }
        elsif ($ch eq '}') {
            $depth--;

            if ($depth == 0) {
                return substr($src, $start, $pos + 1 - $start);
            }
        }

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_211(
        File::Spec->catfile('.', 'Mediabot', 'External.pm')
    );

    my $tmdb_ctx = _extract_sub_211($src, 'mbTMDBSearch_ctx');
    my $tmdb_info = _extract_sub_211($src, 'get_tmdb_info');

    $assert->ok(
        defined $tmdb_ctx && $tmdb_ctx ne '',
        'mbTMDBSearch_ctx body found'
    );

    $assert->ok(
        defined $tmdb_info && $tmdb_info ne '',
        'get_tmdb_info body found'
    );

    $assert->like(
        $tmdb_ctx // '',
        qr/get_tmdb_info\(\$api_key,\s*\$lang,\s*\$query,\s*\$self->\{logger\}\)/,
        'mbTMDBSearch_ctx passes logger to get_tmdb_info'
    );

    $assert->like(
        $tmdb_info // '',
        qr/my\s+\(\$api_key,\s*\$lang,\s*\$query,\s*\$logger\)\s*=\s*\@_;/,
        'get_tmdb_info accepts optional logger'
    );

    $assert->like(
        $tmdb_info // '',
        qr/\$logger->log\(3,\s*"get_tmdb_info\(\) HTTP error: \$status \$reason"\)/,
        'get_tmdb_info logs HTTP errors through logger'
    );

    $assert->like(
        $tmdb_info // '',
        qr/\$logger->log\(3,\s*"get_tmdb_info\(\) empty response"\)/,
        'get_tmdb_info logs empty responses through logger'
    );

    $assert->like(
        $tmdb_info // '',
        qr/\$logger->log\(3,\s*"get_tmdb_info\(\) JSON decode error: \$err"\)/,
        'get_tmdb_info logs JSON decode errors through logger'
    );

    $assert->like(
        $tmdb_info // '',
        qr/\$logger->log\(4,\s*"get_tmdb_info\(\) no results in TMDB response"\)/,
        'get_tmdb_info logs no-result responses through logger'
    );

    $assert->unlike(
        $tmdb_info // '',
        qr/warn\s+"get_tmdb_info\(\)/,
        'get_tmdb_info no longer writes direct STDERR warn'
    );
};
