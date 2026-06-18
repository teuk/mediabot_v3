# t/cases/71_scheduler_runtime_safety.t
# =============================================================================
# Static regression checks for Mediabot::Scheduler runtime state safety.
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

    my $depth      = 0;
    my $in_single  = 0;
    my $in_double  = 0;
    my $in_comment = 0;
    my $escape     = 0;

    for (my $i = $brace; $i < length($src); $i++) {
        my $c = substr($src, $i, 1);

        if ($in_comment) {
            $in_comment = 0 if $c eq "\n";
            next;
        }

        if ($in_single) {
            if ($c eq "\\" && !$escape) {
                $escape = 1;
                next;
            }

            if ($c eq "'" && !$escape) {
                $in_single = 0;
            }

            $escape = 0;
            next;
        }

        if ($in_double) {
            if ($c eq "\\" && !$escape) {
                $escape = 1;
                next;
            }

            if ($c eq '"' && !$escape) {
                $in_double = 0;
            }

            $escape = 0;
            next;
        }

        if ($c eq "#") {
            $in_comment = 1;
            next;
        }

        if ($c eq "'") {
            $in_single = 1;
            next;
        }

        if ($c eq '"') {
            $in_double = 1;
            next;
        }

        if ($c eq "{") {
            $depth++;
        }
        elsif ($c eq "}") {
            $depth--;

            if ($depth == 0) {
                return substr($src, $start, $i - $start + 1);
            }
        }
    }

    die "end of sub $name not found";
}

return sub {
    my ($assert) = @_;

    my $src    = _slurp_scheduler_safety(File::Spec->catfile('.', 'Mediabot', 'Scheduler.pm'));
    my $add    = _extract_sub_scheduler_safety($src, 'add');
    my $start  = _extract_sub_scheduler_safety($src, 'start');
    my $stop   = _extract_sub_scheduler_safety($src, 'stop');
    my $remove = _extract_sub_scheduler_safety($src, 'remove');
    my $restart = _extract_sub_scheduler_safety($src, 'restart');

    $assert->ok(
        $add =~ /cb must be a CODE reference/,
        'Scheduler::add validates callback type'
    );

    $assert->ok(
        $add =~ /interval must be a positive integer/,
        'Scheduler::add validates interval as positive integer'
    );

    $assert->ok(
        $add =~ /invalid task name/,
        'Scheduler::add validates task name'
    );

    $assert->ok(
        $start =~ /my \$ok = eval/,
        'Scheduler::start wraps timer start in eval'
    );

    $assert->ok(
        $start =~ /if \(!\$ok\).*?\$task->\{started\}\s*=\s*1/s,
        'Scheduler::start updates started only after successful start'
    );

    $assert->ok(
        $start =~ /return 0;/ && $start =~ /return 1;/,
        'Scheduler::start returns explicit success/failure'
    );

    $assert->ok(
        $stop =~ /my \$ok = eval/,
        'Scheduler::stop wraps timer stop in eval'
    );

    $assert->ok(
        $stop =~ /if \(!\$ok\).*?\$task->\{started\}\s*=\s*0/s,
        'Scheduler::stop updates started only after successful stop'
    );

    $assert->ok(
        $stop =~ /return 0;/ && $stop =~ /return 1;/,
        'Scheduler::stop returns explicit success/failure'
    );

    $assert->ok(
        $remove =~ /return 0;/ && $remove =~ /return 1;/,
        'Scheduler::remove returns explicit success/failure'
    );

    $assert->ok(
        $restart =~ /return 0 unless \$self->stop\(\$name\)/,
        'Scheduler::restart stops task before starting'
    );

    $assert->ok(
        $restart =~ /return 0 unless \$self->start\(\$name\)/,
        'Scheduler::restart starts task after successful stop'
    );
};
