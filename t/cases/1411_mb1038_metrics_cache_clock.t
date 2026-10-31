use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(decode_utf8);
BEGIN {our $now = 1_900_000_000; *CORE::GLOBAL::time = sub {$main::now}}
use Mediabot::Metrics;
my @warnings; local $SIG{__WARN__} = sub {push @warnings, @_};
my $labels = {channel => '#café'};
sub fixture_1411 {
    my $m = Mediabot::Metrics->new(enabled => 1);
    $m->inc('mediabot_commands_public_total');
    $m->set('mediabot_db_up', 1);
    $m->observe('mediabot_scheduler_tick_seconds', .05, $labels);
    return $m;
}
sub update_1411 {
    my ($m) = @_;
    $m->inc('mediabot_commands_public_total');
    $m->set('mediabot_db_up', 0);
    $m->observe('mediabot_scheduler_tick_seconds', .1, $labels);
}
sub scrape_1411 {
    my ($m) = @_;
    # Execute the real HTTP router, renderer and byte encoder without a listener.
    my $raw = $m->_route_http_request("GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n");
    my ($head, $body) = split /\r\n\r\n/, $raw, 2;
    my ($size) = $head =~ /Content-Length: ([0-9]+)/;
    die 'broken HTTP metrics response' unless $head =~ /\AHTTP\/1\.1 200 OK/
        && defined($size) && $size == length($body) && !utf8::is_utf8($body);
    return decode_utf8($body);
}
sub samples_1411 {
    my ($body) = @_;
    my ($counter) = $body =~ /^mediabot_commands_public_total ([0-9]+)$/m;
    my ($gauge) = $body =~ /^mediabot_db_up ([0-9]+)$/m;
    my ($count) = $body =~ /^mediabot_scheduler_tick_seconds_count\{channel="#café"\} ([0-9]+)$/m;
    return [$counter, $gauge, $count];
}
{
    my $m = fixture_1411(); my $first = scrape_1411($m);
    is_deeply(samples_1411($first), [1,1,1], 'initial HTTP snapshot contains current counter, gauge and labelled histogram');
    update_1411($m); $main::now += 4;
    is(scrape_1411($m), $first, 'ordinary writes retain the deliberate cache during its five-second lifetime');
    ++$main::now;
    is_deeply(samples_1411(scrape_1411($m)), [2,0,2], 'the exact five-second boundary refreshes all observed metric kinds');
}
for my $rewind (1,3600) {
    $main::now = 1_900_000_000;
    my $m = fixture_1411(); scrape_1411($m);
    update_1411($m); $main::now -= $rewind;
    my $fresh = scrape_1411($m);
    is_deeply(samples_1411($fresh), [2,0,2],
        "rewind ${rewind}s: a future-dated cache cannot hide new instrumentation");
    update_1411($m); $main::now += 4;
    is(scrape_1411($m), $fresh,
        "rewind ${rewind}s: the replacement cache still reuses its own fresh five-second generation");
    ++$main::now;
    is_deeply(samples_1411(scrape_1411($m)), [3,0,3],
        "rewind ${rewind}s: normal expiry resumes from the replacement snapshot");
}
{
    $main::now = 1_900_000_000;
    my $m = fixture_1411(); scrape_1411($m);
    update_1411($m); $main::now += 86400;
    is_deeply(samples_1411(scrape_1411($m)), [2,0,2], 'a forward clock jump still expires the old snapshot');
}
{
    my $m = Mediabot::Metrics->new(enabled => 0);
    is(scrape_1411($m), "# Mediabot metrics disabled\n", 'disabled metrics keep their existing HTTP representation');
}
is_deeply(\@warnings, [], 'clock movement and refreshed Unicode labels remain warning-free');
done_testing;
