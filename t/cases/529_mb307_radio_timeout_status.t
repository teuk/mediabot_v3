# t/cases/529_mb307_radio_timeout_status.t
# =============================================================================
# MB307:
#   - signal-terminated yt-dlp jobs must not look like successful exit code 0;
#   - timeouts must reach _finish_download() with timedout => 1;
#   - timeout classification must use the conventional exit code 124.
# =============================================================================

use strict;
use warnings;

return sub {
    my ($assert) = @_;

    # Load Radio::Request in an isolated child process with lightweight stubs.
    # This tests the real helper without changing global state in the static
    # runner or requiring the optional asynchronous runtime modules here.
    my $probe = <<'PROBE';
BEGIN {
    $INC{'IO/Async/Timer/Countdown.pm'} = __FILE__;
    package IO::Async::Timer::Countdown;
    sub import { 1 }

    $INC{'DBI.pm'} = __FILE__;
    package DBI;
    our $errstr = '';
    sub import { 1 }

    $INC{'Mediabot/Helpers.pm'} = __FILE__;
    package Mediabot::Helpers;
    sub import {
        my ($class, @names) = @_;
        my $caller = caller;
        no strict 'refs';
        for my $name (@names) {
            *{"${caller}::$name"} = sub { 1 };
        }
    }

    $INC{'Mediabot/Liquidsoap.pm'} = __FILE__;
    package Mediabot::Liquidsoap;
    sub import { 1 }
}

use lib '.';
use Mediabot::Radio::Request;

my @cases = (
    [0,        0],
    [7 << 8,   0],
    [15,       0],
    [9,        1],
    [0,        1],
);

for my $case (@cases) {
    my ($status, $timedout) = @$case;
    my ($exit, $signal) = Mediabot::Radio::Request::_decode_wait_status(
        $status,
        $timedout,
    );
    print "$exit:$signal\n";
}
PROBE

    open my $fh, '-|', $^X, '-I.', '-e', $probe
        or die "could not start MB307 probe: $!";

    local $/;
    my $output = <$fh> // '';
    close $fh;
    my $rc = $? >> 8;

    $output =~ s/\s+\z//;

    $assert->is(
        $rc,
        0,
        'isolated radio wait-status probe exits successfully'
    );

    $assert->is(
        $output,
        "0:0\n7:0\n143:15\n124:9\n124:0",
        'normal exits, signals and timeouts get distinct conventional codes'
    );

    open my $src_fh, '<:encoding(UTF-8)', 'Mediabot/Radio/Request.pm'
        or die $!;
    local $/;
    my $src = <$src_fh>;
    close $src_fh;

    $assert->like(
        $src,
        qr/timed_out\s*=>\s*0/,
        'download job initializes timeout state'
    );

    $assert->like(
        $src,
        qr/\$job->\{timed_out\}\s*=\s*1/,
        'timeout path records timeout state'
    );

    $assert->like(
        $src,
        qr/my\s+\$wait_status\s*=\s*\$\?/,
        'wait status is captured immediately after waitpid'
    );

    $assert->like(
        $src,
        qr/timedout\s*=>\s*\$timedout/,
        'download completion receives the timeout flag'
    );
};
