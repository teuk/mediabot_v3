# t/cases/21_partyline_schedule_control.t
# =============================================================================
# Static regression checks for Partyline .schedule control.
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

    my $src = _slurp_partyline_schedule(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));

    $assert->ok(
        $src =~ /\.schedule\(\?:\\s\+\(\.\*\)\)\?\$/,
        'Partyline dispatches .schedule'
    );

    $assert->ok(
        $src =~ /sub _cmd_schedule/,
        'Partyline implements _cmd_schedule'
    );

    $assert->ok(
        $src =~ /Access denied: \.schedule requires Master or Owner level/,
        '.schedule is restricted to Master or Owner'
    );

    $assert->ok(
        $src =~ /status <name> \| start <name> \| stop <name> \| restart <name>/,
        '.schedule usage documents supported actions'
    );

    $assert->ok(
        $src =~ /\$sched->can\('task_info'\)/,
        '.schedule uses task_info when available'
    );

    $assert->ok(
        $src =~ /\$sched->all_info/,
        '.schedule falls back to all_info when task_info is unavailable'
    );

    $assert->ok(
        $src =~ /Partyline \.schedule \$action \$name failed/,
        '.schedule logs scheduler action failures'
    );

    $assert->ok(
        $src =~ /Scheduler action failed for '\$name'/,
        '.schedule reports scheduler action failures to the Partyline'
    );

    $assert->ok(
        $src =~ /\$sched->start\(\$name\)/,
        '.schedule can start tasks'
    );

    $assert->ok(
        $src =~ /\$sched->stop\(\$name\)/,
        '.schedule can stop tasks'
    );

    $assert->ok(
        $src =~ /Scheduler task '\$name' restarted/,
        '.schedule can restart tasks'
    );

    $assert->ok(
        $src =~ /\.schedule <list\|status\|start\|stop\|restart>/,
        '.help documents .schedule'
    );

    my $ban_dispatch_count = () = $src =~ /_cmd_ban\(\$stream, \$id/g;
    $assert->is(
        $ban_dispatch_count,
        1,
        'Partyline has only one .ban dispatch block'
    );

    my $ban_help_count = () = $src =~ /^\s*\.\s*"\s+\.ban #chan <nick>/mg;
    $assert->is(
        $ban_help_count,
        1,
        'Partyline help has only one real .ban help line'
    );
};
