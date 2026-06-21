# t/cases/543_mb321_youtube_search_process_watch.t
# =============================================================================
# MB321/MB322: retain the experimental process watcher for future redesign,
# but ensure the production command does not invoke it after runtime timeouts.
# =============================================================================

use strict;
use warnings;
use File::Spec;

sub _slurp_mb321 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_mb321 {
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

    my $src = _slurp_mb321(
        File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm')
    );
    my $async   = _extract_mb321($src, '_youtube_search_fetch_async');
    my $command = _extract_mb321($src, 'youtubeSearch_ctx');

    $assert->ok(defined $async, 'YouTube async worker found');
    $assert->like($async // '', qr/MB321: IO::Async owns SIGCHLD\/process collection/,
        'regression rationale is documented next to the implementation');
    $assert->like($async // '', qr/\$loop->can\('watch_process'\)/,
        'loop capability is checked before forking');
    $assert->like($async // '', qr/\$loop->watch_process\(\s*\$child_pid/s,
        'child PID is registered with IO::Async watch_process');
    $assert->like($async // '', qr/my \(\$pid, \$wait_status\) = \@_/,
        'process callback receives the raw child wait status');
    $assert->like($async // '', qr/\$state->\{wait_status\} = \$wait_status/,
        'loop-provided wait status is preserved');
    $assert->like($async // '', qr/\$state->\{child_done\}\s*=\s*1/,
        'process callback marks the child complete');
    my $async_code = $async // '';
    $async_code =~ s/#.*$//mg;
    $assert->unlike($async_code, qr/\bwaitpid\s*\(/,
        'manual waitpid is completely absent from executable code');
    $assert->unlike($async // '', qr/POSIX::WNOHANG/,
        'manual WNOHANG polling is completely absent');
    $assert->like($async // '', qr/worker_decode_failed/,
        'invalid worker payloads retain a diagnostic status');
    $assert->like($async // '', qr/worker_exception/,
        'child exceptions retain a diagnostic status');
    $assert->like($async // '', qr/worker_setup_failed/,
        'process-watch setup failures retain a diagnostic status');
    $assert->like($async // '', qr/worker_timeout/,
        'worker timeouts retain a diagnostic status');
    $assert->like($async // '', qr/kill 'TERM', \$child_pid/,
        'timeout still sends TERM first');
    $assert->like($async // '', qr/kill 'KILL', \$child_pid/,
        'timeout still escalates to KILL');

    $assert->ok(defined $command, 'YouTube command callback found');
    $assert->unlike($command // '', qr/_youtube_search_fetch_async\(/,
        'MB322 keeps the experimental worker out of the production command');
    $assert->like($command // '', qr/_youtube_search_fetch_sync\(\$api_key,\s*\$query_txt\)/,
        'MB322 production command uses the reliable transport');
};
