# t/cases/444_mb230_event_bus_dynamic_listener_preservation.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    eval { require Mediabot::EventBus; 1 }
        or do { $assert->(0, "cannot load Mediabot::EventBus: $@"); return; };

    my $bus = Mediabot::EventBus->new();
    my @seen;

    $bus->on('spell_cast', sub {
        push @seen, 'first';
        $bus->on('spell_cast', sub { push @seen, 'late' }, name => 'late', priority => 5);
    }, name => 'first', priority => 10);

    my $ran_first = $bus->emit('spell cast');
    $assert->($ran_first == 1, 'listener added during emit does not run in same emit');
    $assert->(join(',', @seen) eq 'first', 'first emit only runs snapshot listener');
    $assert->($bus->listener_count('spell_cast') == 2, 'listener added during emit remains registered');

    my $ran_second = $bus->emit('spell_cast');
    $assert->($ran_second == 2, 'second emit runs preserved dynamic listener');
    $assert->((grep { $_ eq 'late' } @seen) ? 1 : 0, 'dynamic listener ran on later emit');

    my $once_count = 0;
    $bus->once('once_event', sub {
        $once_count++;
        $bus->on('once_event', sub { $once_count += 10 }, name => 'late-once');
    }, name => 'once-adder');

    my $once_first = $bus->emit('once_event');
    $assert->($once_first == 1 && $once_count == 1,
        'once listener added dynamic listener but only snapshot ran first');
    $assert->($bus->listener_count('once_event') == 1,
        'once listener removed without deleting dynamic listener');

    my $once_second = $bus->emit('once_event');
    $assert->($once_second == 1 && $once_count == 11,
        'dynamic listener from once emit survives and runs later');

    my $report_count = 0;
    $bus->on('report_event', sub {
        $report_count++;
        $bus->on('report_event', sub { $report_count += 10 }, name => 'report-late');
    }, name => 'report-first');

    my $report = $bus->emit_report('report_event');
    $assert->($report->{ran} == 1 && $report_count == 1,
        'emit_report also runs only initial snapshot first');
    $assert->($bus->listener_count('report_event') == 2,
        'emit_report preserves listener registered during emit_report');

    $bus->emit_report('report_event');
    $assert->($report_count >= 11,
        'listener registered during emit_report runs on later report');

    my $src = File::Spec->catfile($root, 'Mediabot', 'EventBus.pm');
    open my $fh, '<', $src
        or do { $assert->(0, "cannot open EventBus.pm: $!"); return; };
    my $text = do { local $/; <$fh> };
    close $fh;

    $assert->($text =~ /mb230-B2/, 'EventBus source contains mb230 dynamic listener marker');
    $assert->($text !~ /\b(?:system|qx)\s*(?:\(|\/|\{)|`[^`]+`/,
        'EventBus dynamic listener fix does not introduce shell execution');
};

if (caller) { return $case; }

my $tests = 0;
my $fail  = 0;

my $assert = sub {
    my ($ok, $name) = @_;
    $tests++;
    $name = 'unnamed assertion' unless defined $name && $name ne '';
    if ($ok) { print "ok $tests - $name\n"; }
    else     { print "not ok $tests - $name\n"; $fail++; }
};

$case->($assert);
print "1..$tests\n";
exit($fail ? 1 : 0);
