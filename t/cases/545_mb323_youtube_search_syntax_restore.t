# t/cases/545_mb323_youtube_search_syntax_restore.t
# =============================================================================
# MB323: regression guard for the production YouTube search hotfix.
# The MB322 generator left an async-callback tail (`}, );`) inside the restored
# synchronous command and made the complete application fail to compile.
# =============================================================================

use strict;
use warnings;

use File::Spec;

sub _slurp_mb323 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path
        or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_mb323(
        File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm')
    );

    my $start = index($src, 'sub youtubeSearch_ctx {');
    my $end   = index($src, "\n\n# Return the Fortnite account id", $start);

    $assert->ok($start >= 0, 'youtubeSearch_ctx start marker found');
    $assert->ok($end > $start, 'youtubeSearch_ctx end marker found');

    my $command = ($start >= 0 && $end > $start)
        ? substr($src, $start, $end - $start)
        : '';

    $assert->like(
        $command,
        qr/MB323: restore the proven synchronous transport/,
        'MB323 production restoration is documented'
    );

    $assert->like(
        $command,
        qr/_youtube_search_fetch_sync\(\$api_key,\s*\$query_txt\)/,
        'live command uses the reliable synchronous transport'
    );

    $assert->unlike(
        $command,
        qr/_youtube_search_fetch_async\(/,
        'live command does not invoke the failed async worker'
    );

    $assert->like(
        $command,
        qr/for\s+my\s+\$i\s*\(0\s*\.\.\s*\$#formatted\).*?\$ctx->reply/s,
        'all formatted search results are emitted through Context'
    );

    $assert->like(
        $command,
        qr/Mediabot::Helpers::logBot\(\s*\$self,\s*\$log_message,\s*\$log_channel,\s*'yt',\s*\$query_txt/s,
        'successful search keeps historical command logging'
    );

    $assert->like(
        $command,
        qr/return\s+1;\s*\}\s*\z/s,
        'command ends with a normal return and one subroutine closing brace'
    );

    $assert->unlike(
        $command,
        qr/\}\s*,\s*\);\s*\}/s,
        'orphaned async callback tail is absent'
    );
};
