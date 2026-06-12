# t/cases/403_mb164_onstarttimers_stage_fresh_before_publish.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    my $file = File::Spec->catfile($root, 'Mediabot', 'DBCommands.pm');

    open my $fh, '<', $file
        or do { $assert->(0, "cannot open DBCommands.pm: $!"); return; };
    my $src = do { local $/; <$fh> };
    close $fh;

    my ($start) = $src =~ /sub onStartTimers \{(.*?)^sub mbAddTimer_ctx/ms;

    $assert->(defined($start) && length($start) > 0,
        'onStartTimers block extracted');

    $assert->($start =~ /mb164-B1: stage the fresh timer object only/,
        'fetch loop documents fresh timer staging');
    $assert->($start !~ /\$hTimers\{\$name\} = \$timer;\s*\$self->\{loop\}->add\(\$timer\);\s*\$timer->start;/s,
        'old start-inside-fetch-loop pattern is gone');
    $assert->($start =~ /\$hTimers\{\$name\} = \$timer;\s*\$i\+\+;/s,
        'fetch loop only stores timer object and increments count');

    $assert->($start =~ /my \@started_fresh;/,
        'commit path tracks fresh timers that were started');
    $assert->($start =~ /for my \$timer_name \(sort keys %hTimers\)/,
        'commit path starts all staged fresh timers deterministically');
    $assert->($start =~ /\$self->\{loop\}->add\(\$timer\).*?\$timer->start/s,
        'commit path adds and starts fresh timers');
    $assert->($start =~ /unless \(\$ok\).*?for my \$started \(\@started_fresh\).*?\$started->stop if \$started->can\('stop'\).*?\$self->\{loop\}->remove\(\$started\).*?return 0;/s,
        'failed fresh start rolls back already-started fresh timers and keeps old timers alive');

    my $idx_start_fresh = index($start, 'for my $timer_name (sort keys %hTimers)');
    my $idx_stop_old    = index($start, '$self->_stop_all_runtime_db_timers();');
    my $idx_publish     = index($start, '%{$self->{hTimers}} = %hTimers');

    $assert->($idx_start_fresh >= 0 && $idx_stop_old >= 0 && $idx_start_fresh < $idx_stop_old,
        'fresh timers are started before old timers are stopped');
    $assert->($idx_stop_old >= 0 && $idx_publish >= 0 && $idx_stop_old < $idx_publish,
        'old timers are stopped immediately before publishing fresh hash');
    $assert->($start =~ /All fresh timers are alive\. Now stop\/remove the old registered timers/,
        'commit path documents all-fresh-before-stop-old invariant');
};

if (caller) { return $case; }

my $tests = 0;
my $fail  = 0;

my $assert = sub {
    my ($ok, $name) = @_;
    $tests++;
    $name = 'unnamed assertion' unless defined $name && $name ne '';

    if ($ok) {
        print "ok $tests - $name\n";
    }
    else {
        print "not ok $tests - $name\n";
        $fail++;
    }
};

$case->($assert);
print "1..$tests\n";
exit($fail ? 1 : 0);
