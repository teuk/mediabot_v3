# t/cases/149_tmdb_repair_mojibake_query.t
# =============================================================================
# Regression checks for TMDB query mojibake repair.
#
# IRC clients or servers can sometimes pass UTF-8 text as mojibake:
#   piège -> piÃ¨ge
# TMDB search should repair that before building the API query.
# =============================================================================

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_tmdb_mojibake {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_tmdb_mojibake {
    my ($src, $sub_name) = @_;

    my $start_re = qr/^sub\s+\Q$sub_name\E\s*\{/m;
    return undef unless $src =~ /$start_re/g;

    my $start = pos($src);
    my $depth = 1;
    my $pos   = $start;
    my $len   = length($src);

    while ($pos < $len) {
        my $char = substr($src, $pos, 1);

        if ($char eq '{') {
            $depth++;
        }
        elsif ($char eq '}') {
            $depth--;

            if ($depth == 0) {
                return substr($src, $start, $pos - $start);
            }
        }

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    require Mediabot::External;

    my $src = _slurp_tmdb_mojibake(
        File::Spec->catfile('.', 'Mediabot', 'External.pm')
    );

    my $helper_body = _extract_sub_body_tmdb_mojibake($src, '_repair_utf8_mojibake');
    my $tmdb_body   = _extract_sub_body_tmdb_mojibake($src, 'mbTMDBSearch_ctx');

    $assert->ok(
        defined $helper_body,
        '_repair_utf8_mojibake body found'
    );

    $assert->ok(
        defined $tmdb_body,
        'mbTMDBSearch_ctx body found'
    );

    $assert->like(
        $src,
        qr/^use Encode qw\(encode decode\);$/m,
        'External.pm imports Encode helpers for mojibake conversion'
    );

    $assert->is(
        Mediabot::External::_repair_utf8_mojibake('piÃ¨ge de cristal'),
        'piège de cristal',
        'mojibake piÃ¨ge is repaired to piège'
    );

    $assert->is(
        Mediabot::External::_repair_utf8_mojibake('AmÃ©lie'),
        'Amélie',
        'mojibake AmÃ©lie is repaired to Amélie'
    );

    $assert->is(
        Mediabot::External::_repair_utf8_mojibake('Lâ€™Ã©tÃ© meurtrier'),
        'L’été meurtrier',
        'CP1252-style mojibake apostrophe and accents are repaired'
    );

    $assert->is(
        Mediabot::External::_repair_utf8_mojibake('piège de cristal'),
        'piège de cristal',
        'valid UTF-8-looking French query is left unchanged'
    );

    $assert->like(
        $tmdb_body // '',
        qr/my \$raw_query = \$query;/,
        'mbTMDBSearch_ctx keeps the raw query for logging'
    );

    $assert->like(
        $tmdb_body // '',
        qr/\$query = _repair_utf8_mojibake\(\$query\);/,
        'mbTMDBSearch_ctx repairs mojibake before TMDB lookup'
    );

    $assert->like(
        $tmdb_body // '',
        qr/repaired mojibake query/,
        'mbTMDBSearch_ctx logs repaired mojibake queries'
    );

    $assert->like(
        $tmdb_body // '',
        qr/get_tmdb_info\(\$api_key, \$lang, \$query, \$self->\{logger\}\)/,
        'mbTMDBSearch_ctx sends the repaired query and logger to get_tmdb_info'
    );
};
