# t/cases/21_partyline_schedule_control.t
# =============================================================================
# Regression checks for Partyline .schedule control and truthful feedback.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_partyline_schedule {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_partyline_schedule(
        File::Spec->catfile('.', 'Mediabot', 'Partyline.pm')
    );

    $assert->like($src, qr/elsif \(\$line =~ \/\^\\\.schedule/,
        'Partyline dispatches .schedule');
    $assert->like($src, qr/sub _cmd_schedule/,
        'Partyline implements _cmd_schedule');
    $assert->like($src,
        qr/Access denied: \.schedule requires Master or Owner level/,
        '.schedule is restricted to Master or Owner');
    $assert->like($src,
        qr/Usage: \.schedule <list\|status\|start\|stop\|restart>/,
        '.schedule usage documents all supported actions');
    $assert->like($src, qr/\$sched->can\('task_info'\)/,
        '.schedule uses task_info when available');
    $assert->like($src, qr/for my \$info \(\$sched->all_info\)/,
        '.schedule has an all_info fallback');
    $assert->like($src,
        qr/Partyline \.schedule \$act \$name failed/,
        '.schedule logs scheduler action failures');
    $assert->like($src,
        qr/Scheduler action failed for '\$name' \(\$act\)/,
        '.schedule reports scheduler action failures');
    $assert->like($src, qr/\$sched->start\(\$name\)/,
        '.schedule checks the result of start');
    $assert->like($src, qr/\$sched->stop\(\$name\)/,
        '.schedule checks the result of stop');
    $assert->like($src, qr/\$sched->restart\(\$name\)/,
        '.schedule checks the result of restart');
    $assert->like($src, qr/is already running/,
        '.schedule reports an already-running task');
    $assert->like($src, qr/is already stopped/,
        '.schedule reports an already-stopped task');
    $assert->like($src, qr/Scheduler task '\$name' not found/,
        '.schedule reports an unknown task');
    $assert->like($src, qr/Scheduler task '\$name' \$verb from Partyline/,
        '.schedule logs successful lifecycle actions');
    $assert->like($src,
        qr/\.schedule <list\|status\|start\|stop\|restart>/,
        '.help documents .schedule');

    my $ban_dispatch_count = () = $src =~ /_cmd_ban\(\$stream, \$id/g;
    $assert->is($ban_dispatch_count, 1,
        'Partyline has only one .ban dispatch block');

    my $ban_help_count = () = $src =~ /^\s*\.\s*"\s+\.ban #chan <nick>/mg;
    $assert->is($ban_help_count, 1,
        'Partyline help has only one real .ban help line');
};
