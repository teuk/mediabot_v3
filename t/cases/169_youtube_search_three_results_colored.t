# t/cases/169_youtube_search_three_results_colored.t
# =============================================================================
# Regression checks for youtubeSearch_ctx() output.
#
# The yt command should fetch the first three results and display them as
# separate visible IRC lines, using the same YouTube label/colors as direct
# YouTube URL previews.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_youtube_three_results {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_youtube_three_results {
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

    my $src = _slurp_youtube_three_results(
        File::Spec->catfile('.', 'Mediabot', 'External.pm')
    );

    my $body = _extract_sub_body_youtube_three_results($src, 'youtubeSearch_ctx');

    $assert->ok(defined $body, 'youtubeSearch_ctx body found');

    $assert->like($body // '', qr/&maxResults=3/, 'youtubeSearch_ctx requests first three results');
    $assert->like($body // '', qr/my \@video_ids;/, 'youtubeSearch_ctx stores ordered video IDs');
    $assert->like($body // '', qr/last if \@video_ids >= 3;/, 'youtubeSearch_ctx limits search IDs to three');
    $assert->like($body // '', qr/my \$ids_enc = join\(',', \@video_ids\);/, 'youtubeSearch_ctx queries videos endpoint with selected IDs');
    $assert->like($body // '', qr/fields=items\(id,snippet\/title,snippet\/channelTitle,contentDetails\/duration,statistics\/viewCount\)/, 'youtubeSearch_ctx requests IDs and metadata');
    $assert->like($body // '', qr/my %video_by_id;/, 'youtubeSearch_ctx maps videos metadata by ID');
    $assert->like($body // '', qr/for my \$video_id \(\@video_ids\)/, 'youtubeSearch_ctx renders results in original order');
    $assert->like($body // '', qr/push \@entries, \$entry;/, 'youtubeSearch_ctx builds colored result entries');

    $assert->like($body // '', qr/one visible line per result/, 'youtubeSearch_ctx documents visible multi-line output');
    $assert->like($body // '', qr/my \$rank = \$i \+ 1;/, 'youtubeSearch_ctx computes a visible result rank');
    $assert->like($body // '', qr/my \$msg\s+= _yt_label\(\);/, 'youtubeSearch_ctx keeps shared [YouTube] label per result');
    $assert->like($body // '', qr/String::IRC->new\(" \$rank\/" \. scalar\(\@entries\) \. " "\)->orange\('black'\)/, 'youtubeSearch_ctx displays rank as colored 1/3 marker');
    $assert->like($body // '', qr/botPrivmsg\(\$self, \$chan, "\(\$nick\) \$msg"\);/, 'youtubeSearch_ctx sends each result as its own IRC line');
    $assert->like($body // '', qr/logBot\(\$self, \$message, \$chan, "yt", \$query_txt\);/, 'youtubeSearch_ctx still logs yt command usage');

    $assert->unlike($body // '', qr/&maxResults=1/, 'youtubeSearch_ctx no longer requests one result');
    $assert->unlike($body // '', qr/String::IRC->new\(" \| "\)->orange\('black'\)/, 'youtubeSearch_ctx no longer squeezes results into one long line');
};
