# t/cases/400_mb149_main_timer_tick_getter_typo.t
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

    my ($setter) = $src =~ /sub setMainTimerTick \{(.*?)^\}/ms;
    my ($getter) = $src =~ /sub getMainTimerTick \{(.*?)^\}/ms;

    $assert->(defined($setter) && length($setter) > 0,
        'setMainTimerTick block extracted');
    $assert->(defined($getter) && length($getter) > 0,
        'getMainTimerTick block extracted');

    $assert->($setter =~ /\$self->\{main_timer_tick\}\s*=\s*\$timer/,
        'setter stores timer in main_timer_tick');
    $assert->($getter =~ /return\s+\$self->\{main_timer_tick\}/,
        'getter returns timer from main_timer_tick');
    $assert->($getter !~ /return\s+\$self->\{maint_timer_tick\}/,
        'old typo maint_timer_tick return is absent from getter');

    $assert->($main_src =~ /setMainTimerTick\(\$timer\)/,
        'mediabot.pl stores main timer handle through setMainTimerTick');
    $assert->($main_src =~ /my \$old_timer = \$mediabot->getMainTimerTick\(\)/,
        'reconnect cleanup reads old main timer through getMainTimerTick');

    $assert->($getter =~ /mb149-B1/,
        'getter contains mb149-B1 marker explaining reconnect impact');
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
