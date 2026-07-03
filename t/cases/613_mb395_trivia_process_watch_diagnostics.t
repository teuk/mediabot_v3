# t/cases/613_mb395_trivia_process_watch_diagnostics.t
# =============================================================================
# MB395:
#   - IO::Async owns SIGCHLD collection, so the trivia worker must use
#     watch_process() instead of racing the loop with manual waitpid polling;
#   - every worker failure must retain enough bounded metadata to explain the
#     live failure without logging the remote question payload.
# =============================================================================

use strict;
use warnings;
use File::Spec;

sub _slurp_mb395 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path
        or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_mb395 {
    my ($src, $name) = @_;

    my $re = qr/^sub\s+\Q$name\E\s*\{/m;
    return undef unless $src =~ /$re/g;

    my $start = $-[0];
    my $pos   = pos($src);
    my $depth = 1;
    my $quote;
    my $escape  = 0;
    my $comment = 0;

    while ($pos < length($src)) {
        my $ch = substr($src, $pos, 1);

        if ($comment) {
            $comment = 0 if $ch eq "\n";
            $pos++;
            next;
        }

        if (defined $quote) {
            if ($escape) {
                $escape = 0;
            }
            elsif ($ch eq '\\') {
                $escape = 1;
            }
            elsif ($ch eq $quote) {
                undef $quote;
            }
            $pos++;
            next;
        }

        if ($ch eq '#') {
            $comment = 1;
        }
        elsif ($ch eq q{'}) {
            $quote = q{'};
        }
        elsif ($ch eq q{"}) {
            $quote = q{"};
        }
        elsif ($ch eq '{') {
            $depth++;
        }
        elsif ($ch eq '}') {
            $depth--;
            return substr($src, $start, $pos + 1 - $start)
                if $depth == 0;
        }

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_mb395(
        File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm')
    );

    my $sync    = _extract_sub_mb395($src, '_trivia_fetch_sync');
    my $async   = _extract_sub_mb395($src, '_trivia_fetch_async');
    my $command = _extract_sub_mb395($src, 'mbTrivia_ctx');

    $assert->ok(defined $sync,    'trivia synchronous worker found');
    $assert->ok(defined $async,   'trivia asynchronous worker found');
    $assert->ok(defined $command, 'trivia command found');

    $assert->like(
        $async // '',
        qr/IO::Async owns SIGCHLD\/process collection/,
        'the process ownership rationale is documented next to the worker'
    );

    $assert->like(
        $async // '',
        qr/\$loop->can\('watch_process'\)/,
        'the loop capability is checked before forking'
    );

    $assert->like(
        $async // '',
        qr/\$loop->watch_process\(\s*\$child_pid/s,
        'the trivia child is registered with IO::Async watch_process'
    );

    $assert->like(
        $async // '',
        qr/my \(\$pid, \$wait_status\) = \@_/,
        'the process callback receives the raw wait status'
    );

    $assert->like(
        $async // '',
        qr/\$state->\{wait_status\}\s*=\s*\$wait_status/,
        'the IO::Async-provided wait status is retained'
    );

    my $async_code = $async // '';
    $async_code =~ s/#.*$//mg;
    $assert->unlike(
        $async_code,
        qr/\bwaitpid\s*\(/,
        'manual waitpid polling is absent from executable trivia code'
    );

    $assert->unlike(
        $async // '',
        qr/POSIX::WNOHANG/,
        'manual WNOHANG polling is absent from the trivia worker'
    );

    for my $error_class (qw(
        worker_setup
        worker_exception
        worker_encode
        worker_payload
        worker_timeout
        worker_failed
        worker_decode
    )) {
        $assert->like(
            $async // '',
            qr/\Q$error_class\E/,
            "async worker preserves $error_class diagnostics"
        );
    }

    $assert->like(
        $async // '',
        qr/trivia worker \$message/,
        'async diagnostics use a dedicated bounded log prefix'
    );

    $assert->like(
        $async // '',
        qr/output_bytes=\$output_bytes/,
        'completion diagnostics include bounded pipe output size'
    );

    $assert->like(
        $async // '',
        qr/elapsed_ms=\$elapsed/,
        'completion diagnostics include worker elapsed time'
    );

    $assert->like(
        $sync // '',
        qr/error\s*=>\s*'http_exception'/,
        'HTTP exceptions retain a distinct error class'
    );

    $assert->like(
        $sync // '',
        qr/content_type\s*=>\s*\$content_type/,
        'remote content type is retained as safe response metadata'
    );

    $assert->like(
        $sync // '',
        qr/content_bytes\s*=>\s*\$content_bytes/,
        'remote payload size is retained without logging payload content'
    );

    $assert->like(
        $command // '',
        qr/trivia request queued channel=\$channel nick=\$nick/,
        'the command logs request identity before starting the worker'
    );

    $assert->like(
        $src,
        qr/debug_label\s*=>\s*"channel=\$channel token=\$request_token requested_by=\$nick"/,
        'the request token is propagated into worker diagnostics'
    );

    $assert->like(
        $command // '',
        qr/worker_output_bytes/,
        'final failure logs include worker transport metadata'
    );

    $assert->like(
        $command // '',
        qr/Details were logged/,
        'IRC failure messages explicitly point to the server diagnostics'
    );

    $assert->unlike(
        $async // '',
        qr/\$state->\{output\}[^;]*logger->log/s,
        'raw child JSON output is never copied into logs'
    );
};
