use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::EventBus;
{
    package MB1137HostilePriority;
    use overload '""' => sub { die 'priority string overload' },
        '0+' => sub { die 'priority number overload' },
        'bool' => sub { die 'priority bool overload' }, fallback => 1;
}
for my $priority (undef, '', 'garbage', '12oops', 'NaN', 'Inf', '-Inf',
                  '1e9999', '-1e9999', "٣", [], {}, bless({},'MB1137HostilePriority')) {
    for my $method ('emit', 'emit_report') {
        my (@seen, @warnings, $entry, $error, $result);
        my $bus = Mediabot::EventBus->new;
        {
            local $SIG{__WARN__} = sub { push @warnings, @_ };
            eval {
                $bus->on(event => sub { push @seen, 'low' }, priority => -1);
                $entry = $bus->once(event => sub { push @seen, 'fallback' }, priority => $priority);
                $bus->on(event => sub { push @seen, 'high' }, priority => 1);
                $result = $bus->$method('event');
                1;
            } or $error = $@;
        }
        ok(!defined($error), 'invalid priority cannot throw or invoke overloads');
        is($entry->{priority}, 0, 'invalid priority is stored as zero');
        is_deeply(\@seen, ['high','fallback','low'], 'priority order remains deterministic');
        is_deeply(\@warnings, [], 'registration and dispatch emit no warnings');
        is($bus->listener_count('event'), 2, 'once lifecycle still removes the fallback listener');
        is(ref($result) ? $result->{ran} : $result, 3, 'all listeners run');
    }
}
for my $case ([0,0], ['-2',-2], ['+3',3], [' 4 ',4], ['1.9',1],
              ['-1.9',-1], ['2e2',200], ['.5',0], ['0 but true',0]) {
    my (@warnings, $entry);
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $entry = Mediabot::EventBus->new->on(event => sub {}, priority => $case->[0]);
    }
    is($entry->{priority}, $case->[1], 'finite numeric priority retains integer conversion');
    is_deeply(\@warnings, [], 'valid numeric priority emits no warning');
}
{
    my $bus = Mediabot::EventBus->new;
    my @seen;
    $bus->on(event => sub { push @seen,'first' }, priority => 0);
    $bus->on(event => sub { push @seen,'second'; die "listener failure\n" }, priority => 'NaN');
    $bus->on(event => sub { push @seen,'third' }, priority => 0);
    my $report = $bus->emit_report('event');
    is_deeply(\@seen, [qw(first second third)], 'equal priorities retain registration order');
    is(scalar @{$report->{errors}}, 1, 'callback exception still reported independently');
    is($report->{ran}, 3, 'callback failure does not stop subsequent listeners');
}
done_testing;
