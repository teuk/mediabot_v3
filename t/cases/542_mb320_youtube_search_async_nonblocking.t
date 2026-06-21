# t/cases/542_mb320_youtube_search_async_nonblocking.t
# =============================================================================
# MB320/MB322: preserve hardened YouTube parsers, formatting and bounded
# HTTP helpers while the production command uses the restored reliable path.
# =============================================================================

use strict;
use warnings;
use File::Spec;

sub _slurp_mb320 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_mb320 {
    my ($src, $name) = @_;
    my $re = qr/^sub\s+\Q$name\E\s*\{/m;
    return undef unless $src =~ /$re/g;
    my ($start, $pos, $depth) = ($-[0], pos($src), 1);
    my ($quote, $escape, $comment);
    while ($pos < length($src)) {
        my $ch = substr($src, $pos, 1);
        if ($comment) { $comment = 0 if $ch eq "\n"; $pos++; next; }
        if (defined $quote) {
            if ($escape) { $escape = 0; $pos++; next; }
            if ($ch eq '\\') { $escape = 1; $pos++; next; }
            if ($ch eq $quote) { undef $quote; $pos++; next; }
            $pos++; next;
        }
        if ($ch eq '#') { $comment = 1; $pos++; next; }
        if ($ch eq "'" || $ch eq '"') { $quote = $ch; $pos++; next; }
        $depth++ if $ch eq '{';
        $depth-- if $ch eq '}';
        return substr($src, $start, $pos + 1 - $start) if $depth == 0;
        $pos++;
    }
    return undef;
}

return sub {
    my ($assert) = @_;
    my $src = _slurp_mb320(File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm'));
    my $parse_ids = _extract_mb320($src, '_youtube_search_parse_ids');
    my $parse_vid = _extract_mb320($src, '_youtube_search_parse_videos');
    my $sync      = _extract_mb320($src, '_youtube_search_fetch_sync');
    my $async     = _extract_mb320($src, '_youtube_search_fetch_async');
    my $command   = _extract_mb320($src, 'youtubeSearch_ctx');

    $assert->ok(defined $parse_ids, 'search parser found');
    $assert->ok(defined $parse_vid, 'metadata parser found');
    $assert->ok(defined $sync, 'blocking worker found');
    $assert->ok(defined $async, 'async worker found');
    $assert->ok(defined $command, 'command callback found');

    $assert->like($async // '', qr/open\(my \$pipe, '-\|'\)/,
        'blocking work runs in a child process');
    $assert->like($async // '', qr/IO::Async::Stream->new/,
        'child output is consumed asynchronously');
    $assert->like($async // '', qr/IO::Async::Timer::Countdown->new/,
        'timeout and reap use asynchronous timers');
    $assert->like($async // '', qr/POSIX::_exit\(0\)/,
        'child exits without inherited object destruction');
    $assert->like($async // '', qr/\$loop->watch_process\(/,
        'child completion is registered with the IO::Async loop');
    my $async_code = $async // '';
    $async_code =~ s/#.*$//mg;
    $assert->unlike($async_code, qr/\bwaitpid\s*\(/,
        'async worker does not race IO::Async with manual waitpid');
    $assert->like($async // '', qr/kill 'TERM', \$child_pid/,
        'timeout sends TERM first');
    $assert->like($async // '', qr/kill 'KILL', \$child_pid/,
        'timeout escalates to KILL');
    $assert->unlike($async // '', qr/waitpid\([^,]+,\s*0\)/,
        'async worker has no blocking waitpid');
    $assert->unlike($async // '', qr/\b(?:sleep|usleep)\s*\(/,
        'async worker has no blocking sleep');
    $assert->unlike($async // '', qr/select\s*\(/,
        'async worker has no blocking select delay');
    $assert->like($async // '', qr/64 \* 1024/,
        'child output is bounded');

    $assert->like($command // '', qr/MB322: emergency runtime restoration/,
        'production fallback is documented');
    $assert->like($command // '', qr/_youtube_search_fetch_sync\(\$api_key,\s*\$query_txt\)/,
        'live command uses the proven transport path');
    $assert->unlike($command // '', qr/_youtube_search_fetch_async\(/,
        'failing forked worker is not used by the live command');
    $assert->like($command // '', qr/\$ctx->reply\(/,
        'results use Context public/private routing');
    $assert->unlike($command // '', qr/_make_http|\$http\w*->get\(/,
        'IRC command callback keeps HTTP details inside the shared worker');

    require JSON::PP;
    my $compiled = eval "package MB320::Probe; use strict; use warnings; $parse_ids $parse_vid 1;";
    $assert->ok($compiled, 'pure YouTube parsers compile in isolation') or return;

    my $ids = MB320::Probe::_youtube_search_parse_ids(JSON::PP::encode_json({
        items => [
            { id => { videoId => 'AAAAAAAAAAA' } },
            { id => { videoId => 'AAAAAAAAAAA' } },
            { id => { videoId => 'BBBBBBBBBBB' } },
            { id => { videoId => 'bad' } },
            { id => { videoId => 'CCCCCCCCCCC' } },
            { id => { videoId => 'DDDDDDDDDDD' } },
        ],
    }));
    $assert->is(join(',', @$ids), 'AAAAAAAAAAA,BBBBBBBBBBB,CCCCCCCCCCC',
        'search parser deduplicates and caps IDs in API order');

    my $videos = MB320::Probe::_youtube_search_parse_videos(
        JSON::PP::encode_json({ items => [
            {
                id => 'BBBBBBBBBBB',
                snippet => { title => 'Second', channelTitle => 'Channel B' },
                contentDetails => { duration => 'PT2M' },
                statistics => { viewCount => '42' },
            },
            {
                id => 'ZZZZZZZZZZZ',
                snippet => { title => 'Unrequested' },
            },
            {
                id => 'AAAAAAAAAAA',
                snippet => { title => 'First', channelTitle => [] },
                contentDetails => { duration => 'PT0S' },
                statistics => { viewCount => 'not-a-number' },
            },
        ] }),
        [qw(AAAAAAAAAAA BBBBBBBBBBB)],
    );

    $assert->is(scalar(keys %$videos), 2,
        'metadata parser keeps only requested IDs');
    $assert->is($videos->{AAAAAAAAAAA}{title}, 'First',
        'requested metadata is preserved');
    $assert->is($videos->{AAAAAAAAAAA}{channel_title}, '',
        'reference-valued channel title is rejected');
    $assert->is($videos->{AAAAAAAAAAA}{views}, '',
        'invalid view count is rejected');
    $assert->is($videos->{BBBBBBBBBBB}{views}, '42',
        'numeric view count is preserved');

    my $bad = MB320::Probe::_youtube_search_parse_ids('{not json');
    $assert->is(scalar(@$bad), 0,
        'malformed search JSON returns no IDs safely');
};
