# t/cases/533_mb311_resolve_async_forward_reverse.t
# =============================================================================
# MB311:
#   - reverse DNS must no longer call blocking gethostbyaddr() in the IRC loop;
#   - forward results must be consumed as soon as the child pipe reaches EOF;
#   - the fixed three-second result delay becomes a real timeout;
#   - completion and timeout replies remain explicit and single-shot.
# =============================================================================

use strict;
use warnings;

use File::Spec;

sub _slurp_mb311 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path
        or die "cannot read $path: $!";

    local $/;
    return <$fh>;
}

sub _extract_sub_mb311 {
    my ($src, $name) = @_;

    my $start_re = qr/^sub\s+\Q$name\E\s*\{/m;
    return undef unless $src =~ /$start_re/g;

    my $start = $-[0];
    my $pos   = pos($src);
    my $depth = 1;

    while ($pos < length($src)) {
        my $char = substr($src, $pos, 1);

        $depth++ if $char eq '{';
        $depth-- if $char eq '}';

        return substr($src, $start, $pos + 1 - $start)
            if $depth == 0;

        $pos++;
    }

    return undef;
}

sub _extract_resolver_program_mb311 {
    my ($body) = @_;

    my $needle = 'my $resolver_code = q{';
    my $start  = index($body, $needle);
    return undef if $start < 0;

    my $pos   = $start + length($needle);
    my $begin = $pos;
    my $depth = 1;

    while ($pos < length($body)) {
        my $char = substr($body, $pos, 1);

        if ($char eq '{') {
            $depth++;
        }
        elsif ($char eq '}') {
            $depth--;
            return substr($body, $begin, $pos - $begin)
                if $depth == 0;
        }

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_mb311(
        File::Spec->catfile('.', 'Mediabot', 'Helpers.pm')
    );

    my $body = _extract_sub_mb311($src, 'resolve_ctx');

    $assert->ok(
        defined $body,
        'resolve_ctx found'
    );

    $assert->like(
        $body // '',
        qr/\$mode\s*=\s*'reverse'/,
        'valid IPv4 input selects asynchronous reverse lookup mode'
    );

    $assert->like(
        $body // '',
        qr/\$mode\s*=\s*'forward'/,
        'valid hostname input selects asynchronous forward lookup mode'
    );

    $assert->unlike(
        $body // '',
        qr/inet_aton\(\$input\)/,
        'the parent no longer performs reverse DNS preparation in the IRC loop'
    );

    $assert->like(
        $body // '',
        qr/open\(\s*my \$pipe,\s*'-\|',\s*\$\^X,\s*'-e',\s*\$resolver_code,\s*\$mode,\s*\$input/s,
        'both lookup modes use the safe argument-list child process'
    );

    $assert->like(
        $body // '',
        qr/read_handle\s*=>\s*\$pipe/,
        'lookup output is attached to IO::Async immediately'
    );

    $assert->like(
        $body // '',
        qr/if\s*\(\$eof\s*&&\s*!\$state->\{pipe_eof\}\+\+\)/,
        'pipe EOF immediately triggers child reaping'
    );

    $assert->like(
        $body // '',
        qr/delay\s*=>\s*3,\s*\n\s*on_expire\s*=>\s*sub\s*\{\s*\n\s*return if \$state->\{finalized\};\s*\n\s*\n\s*\$state->\{timed_out\}\s*=\s*1;/s,
        'three seconds is now a real timeout, not a mandatory result delay'
    );

    $assert->like(
        $body // '',
        qr/DNS lookup timed out for: \$input/,
        'timeout receives an explicit user-facing reply'
    );

    $assert->like(
        $body // '',
        qr/\$state->\{finalized\}\s*=\s*1/,
        'completion is guarded against duplicate callbacks'
    );

    $assert->like(
        $body // '',
        qr/4096\s*-\s*length\(\$state->\{output\}\)/,
        'child output remains bounded'
    );

    my $program = _extract_resolver_program_mb311($body // '');

    $assert->ok(
        defined $program && length $program,
        'isolated resolver child program extracted'
    );

    my $compile_rc = 255;

    if (defined $program) {
        system($^X, '-c', '-e', $program);
        $compile_rc = $? >> 8;
    }

    $assert->is(
        $compile_rc,
        0,
        'resolver child program compiles independently'
    );
};
