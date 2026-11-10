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
    # MB1192: execute registration validation in a private package with inert timers.
    {
        package MB1192Scheduler;
        sub _log { }
        package MB1192Loop;
        sub add { $_[0]{added}++ }
        package MB1192Scalar;
        use overload '""' => sub { die "unexpected parameter stringification\n" }, fallback => 1;
    }
    my $compiled = eval "package MB1192Scheduler; use Scalar::Util qw(weaken refaddr); $add; 1;";
    die $@ unless $compiled;
    no warnings qw(redefine once);
    my $created = 0;
    local *IO::Async::Timer::Periodic::new = sub { $created++; bless {}, 'MB1192Timer' };
    for my $field (qw(name interval first_interval)) {
        my @invalid = $field eq 'name'
            ? ("task\n", "task\r\n", 'bad name', '', 'a' x 65)
            : ("12\n", "12\r\n", "2\x{0662}", "\x{0662}", '1.5', '-1', '');
        push @invalid, [], {}, bless({},'MB1192Scalar');
        push @invalid, 0 if $field eq 'interval';
        for my $value (@invalid) {
            my $loop = bless {}, 'MB1192Loop';
            my $s = bless {_tasks=>{},loop=>$loop}, 'MB1192Scheduler';
            my %args = (name=>'valid', interval=>60, cb=>sub {}, $field=>$value);
            my $before = $created;
            my @warnings;
            my $ok;
            { local $SIG{__WARN__}=sub {push @warnings,@_}; $ok = eval {$s->add(%args);1}; }
            my $error = $@;
            $assert->ok(!$ok, "$field: malformed parameter rejected");
            my $diagnostic = $field eq 'name' ? qr/invalid task name/ : qr/\Q$field\E must be/;
            $assert->like($error,$diagnostic,"$field: controlled validation error");
            $assert->is(scalar keys %{$s->{_tasks}},0,"$field: no task registered");
            $assert->is($created,$before,"$field: no timer constructed");
            $assert->is(scalar @warnings,0,"$field: no coercion warning");
        }
    }
    for my $first (0, '00', 1, '012') {
        my $loop = bless {}, 'MB1192Loop';
        my $s = bless {_tasks=>{},loop=>$loop}, 'MB1192Scheduler';
        $s->add(name=>'Task_1.test:tick-2',interval=>'060',first_interval=>$first,cb=>sub {});
        $assert->is($s->{_tasks}{'Task_1.test:tick-2'}{interval},60,'ASCII interval retains numeric normalization');
        $assert->is($s->{_tasks}{'Task_1.test:tick-2'}{first_interval},0+$first,'zero and leading-zero first intervals remain valid');
        $assert->is($loop->{added},1,'valid periodic task attaches one timer');
    }

};
