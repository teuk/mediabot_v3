# t/cases/399_mb148_runtime_timer_removal_cleanup.t
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

    my ($remtimer) = $src =~ /sub mbRemTimer_ctx \{(.*?)^sub mbTimers_ctx/ms;

    $assert->(defined($remtimer) && length($remtimer) > 0,
        'mbRemTimer_ctx block extracted');

    $assert->($remtimer =~ /mb148-B1: runtime says the timer exists/,
        'DB-missing runtime cleanup has mb148-B1 marker');
    $assert->($remtimer =~ /if \(!defined\(\$rows\) \|\| \$rows < 1\).*?my \$timer = delete \$self->\{hTimers\}\{\$name\}/s,
        'DB-missing branch deletes runtime timer handle');
    $assert->($remtimer =~ /if \(!defined\(\$rows\) \|\| \$rows < 1\).*?\$timer->stop if \$timer->can\('stop'\)/s,
        'DB-missing branch stops runtime timer');
    $assert->($remtimer =~ /if \(!defined\(\$rows\) \|\| \$rows < 1\).*?\$self->\{loop\}->remove\(\$timer\)/s,
        'DB-missing branch removes runtime timer from loop');
    $assert->($remtimer =~ /Timer \$name removed from runtime \(not found in database\)/,
        'DB-missing branch reports runtime cleanup');

    $assert->($remtimer =~ /mb148-B2: stop the Periodic timer/,
        'normal removal cleanup has mb148-B2 marker');
    $assert->($remtimer =~ /my \$timer = delete \$self->\{hTimers\}\{\$name\};\s*if \(\$timer\)/s,
        'normal removal deletes runtime timer handle before cleanup');
    $assert->($remtimer =~ /mb148-B2: stop the Periodic timer.*?\$timer->stop if \$timer->can\('stop'\).*?\$self->\{loop\}->remove\(\$timer\)/s,
        'normal removal stops and removes runtime timer');

    $assert->($remtimer !~ /\$self->\{loop\}->remove\(\$self->\{hTimers\}\{\$name\}\);\s*delete \$self->\{hTimers\}\{\$name\};/s,
        'old remove-without-stop pattern is gone');
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
