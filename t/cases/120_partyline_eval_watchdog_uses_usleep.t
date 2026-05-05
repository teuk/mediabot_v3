# t/cases/120_partyline_eval_watchdog_uses_usleep.t
# =============================================================================
# Regression checks for Partyline .eval watchdog timing.
#
# Perl sleep() is not the right tool for a fractional 0.5 second delay.
# The watchdog should give the eval child a real short grace period after TERM
# before sending KILL, using Time::HiRes::usleep().
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_partyline_watchdog_sleep {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_partyline_watchdog_sleep {
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

    my $src = _slurp_partyline_watchdog_sleep(
        File::Spec->catfile('.', 'Mediabot', 'Partyline.pm')
    );

    my $body = _extract_sub_body_partyline_watchdog_sleep($src, '_cmd_eval');

    $assert->ok(
        defined $body,
        '_cmd_eval body found'
    );

    $assert->like(
        $src,
        qr/^use Time::HiRes qw\(usleep\);$/m,
        'Partyline.pm imports Time::HiRes usleep'
    );

    $assert->unlike(
        $src,
        qr/sleep\(0\.5\)/,
        'Partyline.pm no longer uses sleep(0.5)'
    );

    $assert->ok(
        index($body // '', "kill('TERM', \$pid);") >= 0,
        'eval watchdog sends TERM to child'
    );

    $assert->ok(
        index($body // '', 'usleep(500_000);') >= 0,
        'eval watchdog waits 500ms with usleep'
    );

    $assert->ok(
        index($body // '', "kill('KILL', \$pid);") >= 0,
        'eval watchdog escalates to KILL after grace period'
    );

    $assert->ok(
        index($body // '', "kill('TERM', \$pid);\n            usleep(500_000);\n            kill('KILL', \$pid);") >= 0,
        'TERM/usleep/KILL order is preserved'
    );
};
