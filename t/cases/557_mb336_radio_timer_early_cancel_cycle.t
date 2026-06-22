# t/cases/557_mb336_radio_timer_early_cancel_cycle.t
# =============================================================================
# MB336:
#   Complete the MB326 timer-cycle fix for radio download cancellation.
#
# MB326 broke cycles on normal on_expire terminal paths with `undef`, but a
# timer removed BEFORE its callback fired could never execute that cleanup.
# The remaining affected paths were the Radio::Request poll timer and the
# AdminCommands cancellation reap/kill timers.
# =============================================================================

use strict;
use warnings;

use File::Spec;
use Scalar::Util qw(weaken);

{
    package T557::Timer;
    sub new { my ($class, %args) = @_; bless { %args }, $class }
    sub start { $_[0]{started}++ }
}

sub _slurp_557 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path
        or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_557 {
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
        return substr($src, $start, $pos + 1 - $start) if $depth == 0;
        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $leaked_probe;
    {
        my $bot = { job => {} };
        my @loop;
        my $timer;

        $timer = T557::Timer->new(
            on_expire => sub {
                $timer->start if $timer;
                my $job = $bot->{job};
            },
        );

        $bot->{job}{timer} = $timer;
        push @loop, $timer;
        $leaked_probe = $timer;
        weaken($leaked_probe);

        delete $bot->{job}{timer};
        @loop = ();
        $bot->{job} = {};
    }

    $assert->ok(
        defined $leaked_probe,
        'unweakened captured timer survives early owner removal'
    );

    my $fixed_probe;
    {
        my $bot = { job => {} };
        my @loop;
        my $timer;

        $timer = T557::Timer->new(
            on_expire => sub {
                $timer->start if $timer;
                my $job = $bot->{job};
            },
        );

        $bot->{job}{timer} = $timer;
        push @loop, $timer;

        # Production order: create strong owners first, then weaken only the
        # lexical captured by the callback.
        weaken($timer);
        $fixed_probe = $bot->{job}{timer};
        weaken($fixed_probe);

        delete $bot->{job}{timer};
        @loop = ();
        $bot->{job} = {};
    }

    $assert->ok(
        !defined $fixed_probe,
        'weak captured timer is released when early cancellation removes owners'
    );

    my $admin = _slurp_557(
        File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm')
    );
    my $radio = _slurp_557(
        File::Spec->catfile('.', 'Mediabot', 'Radio', 'Request.pm')
    );

    my $cancel = _extract_sub_557($admin, 'radioDlCancel_ctx') // '';
    my $start  = _extract_sub_557($radio, '_start_download') // '';

    $assert->like(
        $admin,
        qr/use\s+Scalar::Util\s+qw\(weaken\)/,
        'AdminCommands imports weaken explicitly'
    );
    $assert->like(
        $radio,
        qr/use\s+Scalar::Util\s+qw\(weaken\)/,
        'Radio::Request imports weaken explicitly'
    );
    $assert->like(
        $cancel,
        qr/MB336-B1/,
        'radio cancellation documents the completed cycle fix'
    );
    $assert->like(
        $cancel,
        qr/\$job->\{cancel_reap_timer\}\s*=\s*\$reap_timer;.*?\$loop->add\(\$reap_timer\);.*?weaken\(\$reap_timer\);.*?\$reap_timer->start/s,
        'reap timer is strongly owned before its captured lexical is weakened'
    );
    $assert->like(
        $cancel,
        qr/\$job->\{cancel_kill_timer\}\s*=\s*\$kill_timer;.*?\$loop->add\(\$kill_timer\);.*?weaken\(\$kill_timer\);.*?\$kill_timer->start/s,
        'kill timer is strongly owned before its captured lexical is weakened'
    );
    $assert->like(
        $start,
        qr/MB336-B1/,
        'radio request poll timer documents the early-cancel cycle fix'
    );
    $assert->like(
        $start,
        qr/\{timer\}\s*=\s*\$timer;.*?\$loop->add\(\$timer\);.*?weaken\(\$timer\);.*?\$timer->start/s,
        'poll timer is strongly owned before its captured lexical is weakened'
    );
};
