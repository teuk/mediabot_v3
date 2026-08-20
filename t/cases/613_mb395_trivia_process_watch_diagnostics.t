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
    open my $fh, '<:raw', $path
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

    my $worker_src = _slurp_mb395(
        File::Spec->catfile('.', 'Mediabot', 'AsyncWorker.pm')
    );

    $assert->like(
        $async // '',
        qr/Mediabot::AsyncWorker->start\(/,
        'trivia delegates process ownership to the shared AsyncWorker'
    );

    $assert->like(
        $worker_src,
        qr/->watch_process\(\s*\$pid,/s,
        'shared AsyncWorker registers children with IO::Async watch_process'
    );

    my $async_code = $async // '';
    $async_code =~ s/#.*$//mg;
    $assert->unlike(
        $async_code,
        qr/\bwaitpid\s*\(/,
        'manual waitpid polling remains absent from executable trivia code'
    );
    $assert->unlike(
        $async_code,
        qr/\b(?:pipe|fork|watch_process)\s*\(/,
        'trivia no longer duplicates shared subprocess mechanics'
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
            "trivia adapter preserves historical $error_class diagnostics"
        );
    }

    $assert->like(
        $async // '',
        qr/trivia worker \$message/,
        'async diagnostics retain the dedicated bounded log prefix'
    );

    $assert->like(
        $async // '',
        qr/worker_output_bytes/,
        'completion diagnostics retain bounded transport size'
    );

    $assert->like(
        $async // '',
        qr/worker_elapsed_ms/,
        'completion diagnostics retain worker elapsed time'
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
