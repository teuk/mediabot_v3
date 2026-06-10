# t/cases/402_mb151_onstarttimers_atomic_reload.t
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

    $assert->($start =~ /mb151-B1: build the fresh timer set first/,
        'onStartTimers documents atomic reload start');
    $assert->($start !~ /reload timers from DB without leaving old Periodic timers alive.*?_stop_all_runtime_db_timers\(\);\s*my %hTimers/s,
        'old mb150 eager-stop pattern is gone');
    $assert->($start =~ /my %hTimers;/,
        'fresh timer hash is still built locally');

    $assert->($start =~ /SQL prepare error.*?keep existing runtime timers alive if DB reload cannot start.*?return 0;/s,
        'prepare failure keeps existing runtime timers alive');
    $assert->($start =~ /SQL execute error.*?keep existing runtime timers alive if DB reload fails.*?return 0;/s,
        'execute failure keeps existing runtime timers alive');
    $assert->($start !~ /SQL prepare error.*?%\{\$self->\{hTimers\}\} = %hTimers.*?return 0;/s,
        'prepare failure no longer clears hTimers');
    $assert->($start !~ /SQL execute error.*?%\{\$self->\{hTimers\}\} = %hTimers.*?return 0;/s,
        'execute failure no longer clears hTimers');

    $assert->($start =~ /DB reload succeeded\. Now replace old runtime timers atomically.*?\$self->_stop_all_runtime_db_timers\(\);\s*%\{\$self->\{hTimers\}\} = %hTimers;\s*return \$i;/s,
        'successful reload stops old timers only at commit point');

    my $idx_stop = index($start, '$self->_stop_all_runtime_db_timers();');
    my $idx_assign = index($start, '%{$self->{hTimers}} = %hTimers');
    $assert->($idx_stop >= 0 && $idx_assign >= 0 && $idx_stop < $idx_assign,
        'successful path stops old timers immediately before publishing fresh hash');
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
