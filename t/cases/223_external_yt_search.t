# t/cases/223_external_yt_search.t
# =============================================================================
# Verify ytSearch_ctx exists, uses Youtube chanset, and calls the search API.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_223 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/; return <$fh>;
}

sub _extract_sub_223 {
    my ($src, $sub_name) = @_;
    my $re = qr/^[ \t]*sub[ \t]+\Q$sub_name\E\b[^{]*\{/m;
    return undef unless $src =~ /$re/g;
    my $start = $-[0]; my $pos = pos($src); my $depth = 1;
    while ($pos < length($src)) {
        my $ch = substr($src, $pos, 1);
        $depth++ if $ch eq '{'; $depth-- if $ch eq '}';
        return substr($src, $start, $pos + 1 - $start) if $depth == 0;
        $pos++;
    }
    return undef;
}

return sub {
    my ($assert) = @_;

    my $src  = _slurp_223(File::Spec->catfile('.', 'Mediabot', 'External.pm'));
    my $body = _extract_sub_223($src, 'ytSearch_ctx');

    $assert->ok(defined $body && $body ne '', 'ytSearch_ctx sub found');

    # Must check Youtube chanset
    $assert->like($body // '', qr/_chanset_ok.*Youtube/,
        'ytSearch_ctx checks Youtube chanset');

    # Must use YouTube search endpoint
    $assert->like($body // '', qr{googleapis\.com/youtube/v3/search},
        'ytSearch_ctx queries YouTube search endpoint');

    # Must default to 3 results while allowing a guarded config override.
    $assert->like($body // '', qr/YT_SEARCH_RESULTS/,
        'ytSearch_ctx reads configurable YT_SEARCH_RESULTS');
    $assert->like($body // '', qr/\/\/ 3/,
        'ytSearch_ctx keeps default result count at 3');
    $assert->like($body // '', qr/\$yt_max\s*=\s*3\s+unless\s+\$yt_max\s*>=\s*1\s*&&\s*\$yt_max\s*<=\s*5/,
        'ytSearch_ctx guards result count between 1 and 5');
    $assert->like($body // '', qr/maxResults=\$yt_max/,
        'ytSearch_ctx uses configured result count in search URL');

    # Must use eval around HTTP
    $assert->like($body // '', qr/eval\s*\{.*http.*get/s,
        'ytSearch_ctx wraps HTTP call in eval');

    # Must use _yt_* colour helpers for output
    $assert->like($body // '', qr/_yt_text|_yt_label|_yt_sep|_yt_meta/,
        'ytSearch_ctx uses yt colour helpers for IRC output');

    # Dispatch: !yt search routes to ytSearch_ctx
    my $mm = _slurp_223(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
    $assert->like($mm, qr/lc.*search.*ytSearch_ctx|ytSearch_ctx.*search/s,
        'Mediabot.pm routes !yt search to ytSearch_ctx');
};
