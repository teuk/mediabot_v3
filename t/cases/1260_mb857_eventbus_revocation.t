use strict;
use warnings;
use lib '.';
use Test::More;
use Mediabot::EventBus;

sub dispatch {
    my ($bus, $method, $event, @args) = @_;
    my $result = $bus->$method($event, @args);
    return ref($result) ? $result : { ran => $result, errors => [] };
}

for my $method (qw(emit emit_report)) {
    {
        note "$method exact removal during delivery";
        my $bus = Mediabot::EventBus->new;
        my (@seen, $removed, $once, $replacement);
        my $shared = sub { push @seen, 'shared' };
        my $controller = $bus->once(event => sub {
            push @seen, 'controller';
            is($bus->off(other => $removed), 0, 'wrong event cannot revoke a listener');
            is($bus->off(event => { %$removed }), 0, 'copied metadata cannot revoke an entry');
            is($bus->off(event => $removed), 1, 'exact pending regular entry removed');
            is($bus->off(event => $once), 1, 'exact pending one-shot removed');
            is($bus->off(event => $removed), 0, 'repeated removal stays idempotent');
            $replacement = $bus->on(event => $shared, name => 'same', plugin => 'fixture');
            my $nested = dispatch($bus, $method, 'event', 'nested');
            is($nested->{ran}, 2, 'nested dispatch sees survivor and new registration only');
        }, priority => 10);
        $removed = $bus->on(event => $shared, name => 'same', plugin => 'fixture');
        $once = $bus->once(event => sub { die "revoked callback must not run\n" });
        $bus->on(event => sub { push @seen, 'survivor' }, priority => -10);
        my $report = dispatch($bus, $method, 'event', 'outer');
        is($report->{ran}, 2, 'outer count excludes revoked entries and nested-only addition');
        is_deeply($report->{errors}, [], 'revoked one-shot contributes no error');
        is_deeply(\@seen, [qw(controller shared survivor survivor)],
            'old entries never resume after nested delivery');
        is($bus->listener_count('event'), 2, 'replacement and survivor remain registered');
        is($bus->off(event => $removed), 0, 'old handle cannot revoke same-callback replacement');
        is(dispatch($bus, $method, 'event')->{ran}, 2, 'later event retains both live listeners');
    }

    for my $global (0, 1) {
        for my $nested (0, 1) {
            {
                note "$method clear=" . ($global ? 'all' : 'event') . " nested=$nested";
                my $bus = Mediabot::EventBus->new;
                my @seen;
                $bus->on(event => sub {
                    push @seen, 'controller';
                    is($global ? $bus->clear : $bus->clear(' EVENT '), $global ? 4 : 3,
                        'clear counts the registrations it removes');
                    $bus->once(event => sub { push @seen, 'new-once' }, name => 'same', priority => 2);
                    $bus->on(event => sub { push @seen, 'new-regular' }, name => 'same');
                    if ($nested) {
                        is(dispatch($bus, $method, 'event')->{ran}, 2,
                            'new generation is available to a nested event');
                    }
                }, priority => 10);
                $bus->on(event => sub { push @seen, 'revoked-regular'; die "revoked regular\n" });
                $bus->once(event => sub { push @seen, 'revoked-once'; die "revoked once\n" });
                $bus->on(other => sub { push @seen, 'other' });
                my $report = dispatch($bus, $method, 'event');
                is($report->{ran}, 1, 'outer event stops invoking cleared registrations');
                is_deeply($report->{errors}, [], 'cleared failures are not reported as executions');
                is_deeply(\@seen, $nested ? [qw(controller new-once new-regular)] : ['controller'],
                    'new entries follow snapshot timing and old entries remain revoked');
                is($bus->listener_count('event'), $nested ? 1 : 2,
                    'old snapshot cleanup preserves newly registered entries');
                is($bus->listener_count('other'), $global ? 0 : 1,
                    'event clear and global clear retain their existing scope');
                is(dispatch($bus, $method, 'event')->{ran}, $nested ? 1 : 2,
                    'next event delivers only live replacement entries');
                is($bus->listener_count('event'), 1, 'new one-shot executes once');
                is(dispatch($bus, $method, 'other')->{ran}, $global ? 0 : 1,
                    'unrelated event delivery follows clear scope');
            }
        }
    }
}

for my $method (qw(emit emit_report)) {
    my $bus = Mediabot::EventBus->new;
    my @seen;
    $bus->on(event => sub { push @seen, 'failing'; die "live failure\n" }, name => 'failing');
    $bus->on(event => sub { push @seen, 'after' }, priority => -1);
    my $report = dispatch($bus, $method, 'event');
    is($report->{ran}, 2, "$method still counts a live failing callback");
    is_deeply(\@seen, [qw(failing after)], "$method preserves failure isolation");
    if ($method eq 'emit_report') {
        is(scalar @{$report->{errors}}, 1, 'live error remains reported once');
        like($report->{errors}[0]{error}, qr/live failure/, 'live error diagnostics remain useful');
    }
}
done_testing;
