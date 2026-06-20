# t/cases/530_mb308_chromium_reap_status.t
# =============================================================================
# MB308:
#   - Chromium closing stdout/stderr must not allow a later blocking waitpid();
#   - a lingering child is bounded by the existing request deadline;
#   - signal termination must not decode as successful exit code 0.
# =============================================================================

use strict;
use warnings;

use File::Spec;

sub _slurp_mb308 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path
        or die "cannot read $path: $!";

    local $/;
    return <$fh>;
}

sub _extract_sub_mb308 {
    my ($src, $name) = @_;

    my $re = qr/^sub\s+\Q$name\E\s*\{/m;
    return undef unless $src =~ /$re/g;

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

return sub {
    my ($assert) = @_;

    my $src = _slurp_mb308(
        File::Spec->catfile('.', 'Mediabot', 'External', 'URL.pm')
    );

    my $wait_sub   = _extract_sub_mb308($src, '_wait_chromium_child');
    my $decode_sub = _extract_sub_mb308($src, '_decode_chromium_wait_status');
    my $fetch_sub  = _extract_sub_mb308($src, '_fetch_url_chromium_dumpdom');

    $assert->ok(
        defined $wait_sub,
        'bounded Chromium wait helper found'
    );

    $assert->ok(
        defined $decode_sub,
        'Chromium wait-status decoder found'
    );

    $assert->ok(
        defined $fetch_sub,
        'Chromium fetch helper found'
    );

    $assert->like(
        $fetch_sub // '',
        qr/_wait_chromium_child\(\$pid,\s*\$deadline\)/,
        'fetch path reaps Chromium against the original request deadline'
    );

    $assert->unlike(
        $fetch_sub // '',
        qr/waitpid\(\$pid,\s*0\)\s*if\s*\$pid/,
        'fetch success path no longer performs an unconditional blocking waitpid'
    );

    $assert->like(
        $fetch_sub // '',
        qr/if\s*\(\$reap_timedout\)/,
        'post-EOF child timeout is handled explicitly'
    );

    $assert->like(
        $fetch_sub // '',
        qr/if\s*\(\$signal\)/,
        'signal-terminated Chromium is rejected explicitly'
    );

    # Exercise the exact helper code in an isolated child Perl process.
    my $probe = join "\n",
        'use strict;',
        'use warnings;',
        'use POSIX qw(WNOHANG);',
        'use Time::HiRes qw(time usleep);',
        $wait_sub,
        $decode_sub,
        q{
my ($ok_exit, $ok_signal) = _decode_chromium_wait_status(7 << 8);
my ($sig_exit, $sig_signal) = _decode_chromium_wait_status(15);

my $pid = fork();
die "fork failed: $!" unless defined $pid;

if ($pid == 0) {
    sleep 10;
    exit 0;
}

my $started = time();
my ($waited, $status, $timedout, $error)
    = _wait_chromium_child($pid, time() + 0.10);

my $elapsed = time() - $started;
my ($timeout_exit, $timeout_signal)
    = _decode_chromium_wait_status($status);

print join('|',
    "$ok_exit:$ok_signal",
    "$sig_exit:$sig_signal",
    ($waited == $pid ? 1 : 0),
    $timedout,
    "$timeout_exit:$timeout_signal",
    ($elapsed < 2.0 ? 1 : 0),
    ($error // ''),
), "\n";
},
    ;

    open my $fh, '-|', $^X, '-e', $probe
        or die "could not start MB308 probe: $!";

    local $/;
    my $output = <$fh> // '';
    close $fh;

    my $rc = $? >> 8;
    $output =~ s/\s+\z//;

    $assert->is(
        $rc,
        0,
        'isolated Chromium child-status probe exits successfully'
    );

    $assert->like(
        $output,
        qr/^7:0\|143:15\|1\|1\|(?:143:15|137:9)\|1\|$/,
        'normal exits, signals and bounded timeout cleanup are decoded correctly'
    );
};
