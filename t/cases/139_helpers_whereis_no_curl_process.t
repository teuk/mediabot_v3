use strict;
use warnings;
use Test::More;
use Socket ();
# Block the historical resolver too, so the same fixture can be run against
# the unpatched module without asking the OS resolver for these names.
our @dns;
BEGIN {
    *CORE::GLOBAL::gethostbyname = sub {
        push @dns, $_[0];
        return $_[0] eq 'dual.example'
            ? Socket::inet_pton(Socket::AF_INET(), '192.0.2.17') : undef;
    };
}
use Mediabot::External::Country qw(whereis);

my $ip4 = '192.0.2.17';
my $ip6 = '2001:db8::17';
my $v4 = {
    family => Socket::AF_INET(),
    addr => Socket::pack_sockaddr_in(0, Socket::inet_pton(Socket::AF_INET(), $ip4)),
};
my $v6 = {
    family => Socket::AF_INET6(),
    addr => Socket::pack_sockaddr_in6(0, Socket::inet_pton(Socket::AF_INET6(), $ip6)),
};
my %answers = (
    'dual.example' => [$v6, $v4],
    'ipv6.example' => [$v6],
);

my (@urls, @options);
my $reply = { success => 1, content => '{"country":" FR "}' };
no warnings qw(redefine once);
local *Socket::getaddrinfo = sub {
    my ($host) = @_;
    push @dns, $host;
    return exists($answers{$host}) ? (0, @{$answers{$host}}) : (1);
};
local *HTTP::Tiny::new = sub {
    my ($class, %args) = @_;
    push @options, \%args;
    return bless {}, 'Whereis139HTTP';
};
local *Whereis139HTTP::get = sub {
    push @urls, $_[1];
    return $reply;
};
my $base = 'https://api.country.is/';
is_deeply([whereis({}, $ip4), \@dns, \@urls, \@options],
    ['FR', [], [$base . $ip4], [{timeout => 3, verify_SSL => 1}]],
    'IPv4 literal sends one short verified HTTPS lookup without DNS');

@urls = ();
is_deeply([whereis({}, ' 2001:0DB8:0:0:0:0:0:17 '), \@dns, \@urls],
    ['FR', [], [$base . $ip6]], 'IPv6 literal is canonicalized without DNS');

@urls = ();
is_deeply([whereis({}, 'ipv6.example'), \@dns, \@urls],
    ['FR', ['ipv6.example'], [$base . $ip6]], 'IPv6-only host sends one lookup to its numeric address');

@dns = @urls = ();
is_deeply([whereis({}, 'dual.example'), \@dns, \@urls],
    ['FR', ['dual.example'], [$base . $ip4]], 'dual-stack hostname still prefers IPv4');

@dns = @urls = ();
my @unavailable = map { whereis({}, $_) }
    (undef, [], ' ', '2001:db8:::17', '2001:db8::17/path', 'missing.example');
is_deeply([\@unavailable, \@dns, \@urls], [[('N/A') x 6], ['missing.example'], []],
    'missing or invalid hosts do not make a geolocation request');

@dns = @urls = ();
is_deeply([whereis({}, 'teuk.USERS.UNDERNET.ORG'), \@dns, \@urls],
    ['on an Undernet hidden host ;)', [], []], 'Undernet hidden host skips DNS and HTTP');

my @results;
for my $response (undef, {success => 0}, {success => 1, content => '{broken'},
        {success => 1, content => '["FR"]'}, {success => 1, content => '{"country":[]}'}) {
    $reply = $response;
    push @results, whereis({}, $ip6);
}
is_deeply(\@results, [('N/A') x 5], 'HTTP and JSON failures give a printable N/A');
done_testing;
