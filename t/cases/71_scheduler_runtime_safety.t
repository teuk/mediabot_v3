# t/cases/71_scheduler_runtime_safety.t
# =============================================================================
# Regression checks for Mediabot::Scheduler runtime state safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_scheduler_safety {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_scheduler_safety {
    my ($src, $name) = @_;
    my $start = index($src, "sub $name");
    die "sub $name not found" if $start < 0;
    my $brace = index($src, "{", $start);
    die "opening brace for $name not found" if $brace < 0;

    my $depth = 0;
    my ($in_single, $in_double, $in_comment, $escape) = (0, 0, 0, 0);
    for (my $i = $brace; $i < length($src); $i++) {
        my $c = substr($src, $i, 1);
        if ($in_comment) { $in_comment = 0 if $c eq "\n"; next }
        if ($in_single) {
            if ($c eq "\\" && !$escape) { $escape = 1; next }
            $in_single = 0 if $c eq "'" && !$escape;
            $escape = 0; next;
        }
        if ($in_double) {
            if ($c eq "\\" && !$escape) { $escape = 1; next }
            $in_double = 0 if $c eq '"' && !$escape;
            $escape = 0; next;
        }
        if ($c eq "#") { $in_comment = 1; next }
        if ($c eq "'") { $in_single = 1; next }
        if ($c eq '"') { $in_double = 1; next }
        $depth++ if $c eq "{";
        if ($c eq "}") {
            $depth--;
            return substr($src, $start, $i - $start + 1) if $depth == 0;
        }
    }
    die "end of sub $name not found";
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_scheduler_safety(
        File::Spec->catfile('.', 'Mediabot', 'Scheduler.pm')
    );
    my $add     = _extract_sub_scheduler_safety($src, 'add');
    my $start   = _extract_sub_scheduler_safety($src, 'start');
    my $stop    = _extract_sub_scheduler_safety($src, 'stop');
    my $remove  = _extract_sub_scheduler_safety($src, 'remove');
    my $restart = _extract_sub_scheduler_safety($src, 'restart');

    $assert->like($add, qr/cb must be a CODE reference/,
        'Scheduler::add validates callback type');
    $assert->like($add, qr/interval must be a positive integer/,
        'Scheduler::add validates interval as positive integer');
    $assert->like($add, qr/invalid task name/,
        'Scheduler::add validates task name');
    $assert->like($add, qr/generation\s*=>\s*0/,
        'Scheduler::add initializes lifecycle generation');

    $assert->like($start, qr/my \$ok = eval/,
        'Scheduler::start wraps timer start in eval');
    $assert->like($start,
        qr/\$task->\{generation\}\+\+.*?\$task->\{started\}\s*=\s*1.*?\$self->_arm_calendar/s,
        'Scheduler::start publishes a generation before calendar arm');
    $assert->like($start,
        qr/if \(!\$ok\).*?\$task->\{generation\}\+\+.*?\$task->\{started\}\s*=\s*0/s,
        'Scheduler::start rolls state back after failed arm');
    $assert->like($start, qr/return 0;/,
        'Scheduler::start returns explicit failure');
    $assert->like($start, qr/return 1;/,
        'Scheduler::start returns explicit success');

    $assert->like($stop, qr/my \$ok = eval/,
        'Scheduler::stop wraps timer stop in eval');
    $assert->like($stop,
        qr/if \(!\$ok\).*?return 0;.*?\$task->\{generation\}\+\+.*?\$task->\{started\}\s*=\s*0/s,
        'Scheduler::stop changes state only after successful stop');
    $assert->like($stop, qr/return 1;/,
        'Scheduler::stop returns explicit success');

    $assert->like($remove,
        qr/return 0 if \$task->\{started\} && !\$self->stop\(\$name\)/,
        'Scheduler::remove refuses to orphan a timer after stop failure');
    $assert->like($remove, qr/return 0;/,
        'Scheduler::remove returns explicit failure');
    $assert->like($remove, qr/return 1;/,
        'Scheduler::remove returns explicit success');

    $assert->like($restart,
        qr/return 0 unless \$self->stop\(\$name\)/,
        'Scheduler::restart stops task before starting');
    $assert->like($restart,
        qr/return 0 unless \$self->start\(\$name\)/,
        'Scheduler::restart starts task after successful stop');
};
