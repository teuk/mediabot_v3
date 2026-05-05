# t/cases/126_test_live_teardown_uses_usleep.t
# =============================================================================
# Regression checks for t/test_live.pl teardown timing.
#
# The live test runner should not use a fractional sleep(0.5). Use
# Time::HiRes::usleep() for the 500ms wait while the bot subprocess exits.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_test_live_usleep {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_test_live_usleep {
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

    my $src = _slurp_test_live_usleep(
        File::Spec->catfile('.', 't', 'test_live.pl')
    );

    my $teardown = _extract_sub_body_test_live_usleep($src, 'teardown');

    $assert->ok(
        defined $teardown,
        'teardown body found in t/test_live.pl'
    );

    $assert->like(
        $src,
        qr/^use Time::HiRes qw\(time usleep\);$/m,
        't/test_live.pl imports Time::HiRes time and usleep'
    );

    $assert->unlike(
        $src,
        qr/^use Time::HiRes qw\((?:sleep time|time sleep)\);$/m,
        't/test_live.pl no longer imports Time::HiRes sleep'
    );

    $assert->unlike(
        $src,
        qr/sleep\(0\.5\)/,
        't/test_live.pl no longer uses sleep(0.5)'
    );

    $assert->like(
        $teardown // '',
        qr/kill 'TERM', \$bot_pid;/,
        'teardown sends TERM to bot subprocess'
    );

    $assert->like(
        $teardown // '',
        qr/usleep\(500_000\);/,
        'teardown waits 500ms with usleep'
    );

    $assert->like(
        $teardown // '',
        qr/\$waited \+= 0\.5;/,
        'teardown still accounts for 0.5s wait increments'
    );

    $assert->like(
        $teardown // '',
        qr/kill 'KILL', \$bot_pid;/,
        'teardown still escalates to KILL if the bot does not exit'
    );
};
