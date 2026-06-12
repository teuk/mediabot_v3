# t/cases/406_mb167_event_bus_foundation.t
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

    $assert->(ref($bus) eq 'Mediabot::EventBus',
        'EventBus object can be created');
    $assert->($bus->listener_count('public_message') == 0,
        'new EventBus starts with no listeners');

    my @seen;
    $bus->on('Public Message', sub {
        my ($payload) = @_;
        push @seen, "low:$payload->{text}";
    }, name => 'low', priority => 0);

    $bus->on('public_message', sub {
        my ($payload) = @_;
        push @seen, "high:$payload->{text}";
    }, name => 'high', priority => 10);

    $assert->($bus->listener_count('public_message') == 2,
        'two listeners registered on normalized event name');

    my $ran = $bus->emit('PUBLIC MESSAGE', { text => 'hello' });
    $assert->($ran == 2,
        'emit returns number of listeners run');
    $assert->(join(',', @seen) eq 'high:hello,low:hello',
        'listeners run in priority order');

    my $once_count = 0;
    $bus->once('shutdown', sub { $once_count++ }, name => 'shutdown-once');
    $assert->($bus->listener_count('shutdown') == 1,
        'once listener registered');
    $bus->emit('shutdown');
    $bus->emit('shutdown');
    $assert->($once_count == 1 && $bus->listener_count('shutdown') == 0,
        'once listener is removed after first emit');

    $bus->on('error_event', sub { die "boom\n" }, name => 'bad', plugin => 'test');
    $bus->on('error_event', sub { push @seen, 'after-error' }, name => 'good');

    my $report = $bus->emit_report('error_event');
    $assert->($report->{ran} == 2,
        'emit_report keeps running listeners after one dies');
    $assert->(ref($report->{errors}) eq 'ARRAY' && @{$report->{errors}} == 1,
        'emit_report returns one structured error');
    $assert->($report->{errors}[0]{name} eq 'bad' && $report->{errors}[0]{plugin} eq 'test',
        'emit_report preserves listener metadata in errors');
    $assert->((grep { $_ eq 'after-error' } @seen) ? 1 : 0,
        'listener after failing listener still ran');

    my @events = $bus->events;
    $assert->((grep { $_ eq 'public_message' } @events) ? 1 : 0,
        'events() lists normalized event names');

    my $cleared = $bus->clear('public_message');
    $assert->($cleared == 2 && $bus->listener_count('public_message') == 0,
        'clear(event) removes listeners for one event');

    my $total_cleared = $bus->clear;
    my @remaining_events = $bus->events;
    $assert->($total_cleared >= 1 && scalar(@remaining_events) == 0,
        'clear() removes all remaining listeners');

    eval { require 'Mediabot/Mediabot.pm'; 1 }
        or do { $assert->(0, "cannot load Mediabot/Mediabot.pm: $@"); return; };

    my $bot = Mediabot->new({});
    $assert->($bot->event_bus && ref($bot->event_bus) eq 'Mediabot::EventBus',
        'Mediabot constructor creates an EventBus');
    $assert->($bot->events == $bot->event_bus,
        'Mediabot->events is a short alias to event_bus');

    my $main_file = File::Spec->catfile($root, 'Mediabot', 'Mediabot.pm');
    open my $mfh, '<', $main_file
        or do { $assert->(0, "cannot open Mediabot.pm: $!"); return; };
    my $main_src = do { local $/; <$mfh> };
    close $mfh;

    $assert->($main_src =~ /use Mediabot::EventBus;/,
        'Mediabot.pm loads Mediabot::EventBus');
    $assert->($main_src =~ /event_bus\s*=>\s*Mediabot::EventBus->new\(\)/,
        'Mediabot object stores EventBus instance');
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
