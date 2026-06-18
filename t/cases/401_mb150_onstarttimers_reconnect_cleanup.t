# t/cases/401_mb150_onstarttimers_reconnect_cleanup.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    my $file = File::Spec->catfile($root, 'Mediabot', 'DBCommands.pm');
    my $main = File::Spec->catfile($root, 'mediabot.pl');

    open my $fh, '<', $file
        or do { $assert->(0, "cannot open DBCommands.pm: $!"); return; };
    my $src = do { local $/; <$fh> };
    close $fh;

    open my $mfh, '<', $main
        or do { $assert->(0, "cannot open mediabot.pl: $!"); return; };
    my $main_src = do { local $/; <$mfh> };
    close $mfh;

    my ($helper) = $src =~ /sub _stop_all_runtime_db_timers \{(.*?)^\}/ms;
    my ($start)  = $src =~ /sub onStartTimers \{(.*?)^sub mbAddTimer_ctx/ms;

    $assert->(defined($helper) && length($helper) > 0,
        '_stop_all_runtime_db_timers helper exists');
    $assert->($src =~ /our\s+\@EXPORT\s*=\s*qw\(.*?_stop_all_runtime_db_timers.*?\);/s,
        '_stop_all_runtime_db_timers is exported so Mediabot method dispatch can find it');
    $assert->(defined($start) && length($start) > 0,
        'onStartTimers block extracted');

    $assert->($src =~ /onStartTimers\(\).*reconnect.*duplicate|duplicate.*onStartTimers\(\).*reconnect/is,
        'helper documentation explains reconnect duplication risk');
    $assert->($helper =~ /\$self->\{hTimers\}\s*=\s*\{\}/,
        'helper clears hTimers before stopping old handles');
    $assert->($helper =~ /for my \$name \(keys %\$timers\)/,
        'helper iterates over previous timer handles');
    $assert->($helper =~ /\$timer->stop if \$timer->can\('stop'\)/,
        'helper stops each old Periodic timer');
    $assert->($helper =~ /\$self->\{loop\}->remove\(\$timer\)/,
        'helper removes each old timer from IO::Async loop');

    $assert->(index($start, '%{$self->{hTimers}} = %hTimers') >= 0,
        'onStartTimers still stores the fresh timer hash');
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
