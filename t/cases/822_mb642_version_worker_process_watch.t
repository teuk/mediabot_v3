# t/cases/822_mb642_version_worker_process_watch.t
# =============================================================================
# mb642/mb652 — IO::Async remains the sole owner of normal child collection.
# In MB652 that ownership moves from Helpers.pm to the shared AsyncWorker.
# =============================================================================

use strict;
use warnings;
use utf8;

sub _slurp_822 {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_822 {
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

    my $hsrc = _slurp_822('Mediabot/Helpers.pm');
    my $awsrc = _slurp_822('Mediabot/AsyncWorker.pm');
    my $usrc = _slurp_822('Mediabot/Update.pm');
    my $async = _extract_822($hsrc, 'getVersion_async');

    $assert->ok(defined $async, 'mb652-822: getVersion_async localisee');

    $assert->like($async // '',
        qr/Mediabot::AsyncWorker->start\(/,
        'mb652-822: version worker uses shared process owner');

    my $exec = $async // '';
    $exec =~ s/#.*$//mg;

    $assert->unlike($exec, qr/\bwatch_process\s*\(/,
        'mb652-822: Helpers no longer registers process watcher itself');
    $assert->unlike($exec, qr/\bwaitpid\s*\(/,
        'mb642-822: Helpers has no competing manual waitpid');
    $assert->unlike($exec, qr/\bWNOHANG\b/,
        'mb642-822: Helpers has no process polling');

    $assert->like($awsrc,
        qr/->watch_process\(\s*\$pid,/s,
        'mb652-822: shared AsyncWorker gives PID ownership to IO::Async');
    $assert->like($awsrc,
        qr/\$self->\{wait_status\}\s*=\s*\$wait_status/,
        'mb652-822: shared worker preserves raw watcher status');

    my $aw_exec = $awsrc;
    $aw_exec =~ s/#.*$//mg;
    # A bounded manual reap is permitted only on setup failure before
    # watch_process accepts ownership; normal lifecycle remains watcher-owned.
    $assert->like($awsrc,
        qr/watch_process never accepted ownership of this PID/,
        'mb652-822: exceptional pre-ownership reap is explicitly scoped');

    $assert->like($async // '',
        qr/_version_asyncworker_reason\(\$result\)/,
        'mb652-822: shared lifecycle errors become version-specific reasons');

    $assert->like($usrc,
        qr/set conf update\.VERSION_URL to override/,
        'mb642-822: update diagnostic still explains version source override');

    $assert->unlike($usrc,
        qr/\(override: conf update\.VERSION_URL\)/,
        'mb642-822: default URLs are still not mislabeled as overrides');
};
