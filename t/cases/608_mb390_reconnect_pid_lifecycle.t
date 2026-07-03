# t/cases/608_mb390_reconnect_pid_lifecycle.t
# =============================================================================
# MB390 release blocker regression:
# - a successful reconnect must release every reconnect guard;
# - foreground and daemon instances must acquire an atomic process-lifetime
#   PID lock before runtime initialisation;
# - clean shutdown removes only the PID file owned by the current process.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../..";
}

use File::Spec;
use File::Temp qw(tempdir);
use POSIX qw(_exit);
use Mediabot::ProcessLock;

sub _slurp_mb390 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_mb390 {
    my ($src, $name) = @_;
    return undef unless $src =~ /^sub\s+\Q$name\E\s*\{/mg;

    my $begin = $-[0];
    my $pos   = pos($src);
    my $depth = 1;
    my $len   = length($src);

    while ($pos < $len) {
        my $char = substr($src, $pos, 1);
        $depth++ if $char eq '{';
        $depth-- if $char eq '}';
        return substr($src, $begin, $pos + 1 - $begin) if $depth == 0;
        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $main = _slurp_mb390(File::Spec->catfile('.', 'mediabot.pl'));
    my $core = _slurp_mb390(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));

    my $reset_sub = _extract_sub_mb390($main, '_reset_irc_reconnect_state');
    $assert->ok(defined $reset_sub, 'shared reconnect-state reset helper exists');

    my $compiled = eval "package MB390::ReconnectHarness; $reset_sub; 1;";
    $assert->ok($compiled, 'reconnect-state reset helper compiles in isolation');

    my $state = {
        irc_restart_in_progress   => 1,
        irc_reconnect_requested   => 1,
        irc_reconnect_in_progress => 1,
    };
    $assert->ok(
        MB390::ReconnectHarness::_reset_irc_reconnect_state($state),
        'reconnect-state helper accepts a bot state'
    );
    $assert->is($state->{irc_restart_in_progress}, 0, 'restart guard is released');
    $assert->is($state->{irc_reconnect_requested}, 0, 'reconnect request is consumed');
    $assert->is($state->{irc_reconnect_in_progress}, 0, 'reconnect in-progress guard is released');

    my $reset_calls = () = $main =~ /_reset_irc_reconnect_state\(\$mediabot\)/g;
    $assert->is($reset_calls, 2, 'both failed and successful reconnect paths reset lifecycle guards');

    $assert->like(
        $main,
        qr/unless \(\$mediabot->acquirePidFile\(\)\)/,
        'main process acquires the PID lock explicitly'
    );
    $assert->like(
        $main,
        qr/Acquire the final process PID after fork\/setsid/s,
        'PID lock is acquired after daemonisation'
    );
    $assert->unlike(
        $main,
        qr/# Update pid file.*?open my \$pid_fh/s,
        'periodic timer no longer rewrites the PID file'
    );
    $assert->like(
        $core,
        qr/\$self->releasePidFile\(\)/,
        'clean shutdown releases the PID lock'
    );

    my $tmp = tempdir(CLEANUP => 1);
    my $pidfile = File::Spec->catfile($tmp, 'mediabot.pid');
    my $lock = Mediabot::ProcessLock->new(path => $pidfile, pid => $$);

    $assert->ok($lock->acquire(), 'first process acquires PID lock');
    $assert->ok(-e $pidfile, 'PID file is created immediately');

    open my $read_fh, '<', $pidfile or die "cannot read $pidfile: $!";
    my $stored = <$read_fh>;
    close $read_fh;
    $stored =~ s/\s+\z//;
    $assert->is($stored, $$, 'PID file contains the owning process PID');

    my $child = fork();
    die "fork failed: $!" unless defined $child;
    if ($child == 0) {
        my $other = Mediabot::ProcessLock->new(path => $pidfile, pid => $$);
        _exit($other->acquire() ? 1 : 0);
    }
    waitpid($child, 0);
    $assert->is($? >> 8, 0, 'concurrent process cannot acquire the locked PID file');

    $assert->ok($lock->release(), 'owner releases PID lock cleanly');
    $assert->ok(!-e $pidfile, 'owned PID file is removed on release');

    open my $stale, '>', $pidfile or die "cannot write stale PID file: $!";
    print {$stale} "2147483647\n";
    close $stale;

    my $replacement = Mediabot::ProcessLock->new(path => $pidfile, pid => $$);
    $assert->ok($replacement->acquire(), 'stale unlocked PID file is replaced');
    $assert->ok($replacement->release(), 'replacement PID lock releases cleanly');
    $assert->ok(!-e $pidfile, 'replacement removes its own PID file');
};
