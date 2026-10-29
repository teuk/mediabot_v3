use strict;
use warnings;
use Test::More;
use IO::Socket::INET;
use IO::Select;
use File::Temp qw(tempdir);
use JSON::PP ();
use POSIX qw(WNOHANG);
use Time::HiRes ();
use Mediabot::External;

# Exercise the actual shared factory and HTTP::Tiny redirect engine. Only the
# remote endpoints are replaced: two bounded, loopback-only HTTP servers.
local %ENV = %ENV;
delete @ENV{qw(http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy NO_PROXY no_proxy)};
$ENV{no_proxy} = '127.0.0.1';
my $tmp = tempdir(CLEANUP => 1);
my $log = "$tmp/requests.jsonl";
my @listeners = map {
    IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0,
        Listen => 8, ReuseAddr => 1, Proto => 'tcp') or die "local listener: $!";
} 1..2;
my ($first, $second) = map {'http://127.0.0.1:'.$_->sockport} @listeners;
my $owner = $$;
my $pid = fork();
die "fork: $!" unless defined $pid;
if (!$pid) {
    local $SIG{ALRM} = sub { POSIX::_exit(124) };
    local $SIG{TERM} = sub { POSIX::_exit(0) };
    local $SIG{PIPE} = 'IGNORE';
    alarm 15;
    my $ready = IO::Select->new(@listeners);
    for (1..64) {
        my ($listener) = $ready->can_read;
        my $client = $listener->accept or POSIX::_exit(125);
        $client->autoflush(1);
        my $request = <$client> // '';
        my ($method, $path) = $request =~ /\A([A-Z]+) (\S+) HTTP\/1\.[01]\r?\n\z/;
        POSIX::_exit(126) unless defined $path;
        my %headers;
        my $header_bytes = length $request;
        while (defined(my $line = <$client>)) {
            last if $line =~ /\A\r?\n\z/;
            $header_bytes += length $line;
            POSIX::_exit(126) if $header_bytes > 8192;
            my ($key, $value) = $line =~ /\A([^:]+):\s*(.*?)\r?\n\z/;
            $headers{lc $key} = $value if defined $key;
        }
        my $length = $headers{'content-length'} // 0;
        POSIX::_exit(126) unless $length =~ /\A[0-9]+\z/ && $length <= 65536;
        my $body = '';
        while (length($body) < $length) {
            my $n = read($client, my $chunk, $length-length($body));
            POSIX::_exit(126) unless $n;
            $body .= $chunk;
        }
        # Record only public fixture metadata and booleans, never token values.
        open my $fh, '>>:raw', $log or POSIX::_exit(126);
        print {$fh} JSON::PP::encode_json({method=>$method, path=>$path,
            origin=>$listener->sockport == $listeners[0]->sockport ? 'first' : 'second',
            authorization=>exists($headers{authorization}) ? 1 : 0,
            body_bytes=>length($body)}), "\n" or POSIX::_exit(126);
        close $fh or POSIX::_exit(126);
        my ($status, $location, $content) = (200, '', 'done');
        if ($path eq '/chain/start') { ($status,$location) = (302, '/chain/middle') }
        elsif ($path eq '/chain/middle') { ($status,$location) = (302, '/finish') }
        elsif ($path eq '/submit') { ($status,$location) = (303, "$second/escaped") }
        elsif ($path eq '/post307') { ($status,$location) = (307, "$second/escaped") }
        elsif ($path eq '/search') { ($status,$location) = (303, "$second/search-final") }
        elsif ($path eq '/search-final' || $path eq '/escaped') { $content = '{"results":[]}' }
        elsif ($path eq '/oversized') { $content = 'x' x 128 }
        print {$client} "HTTP/1.1 $status Fixture\r\nConnection: close\r\nContent-Type: application/json\r\n",
            ($location ne '' ? "Location: $location\r\n" : ''),
            'Content-Length: '.length($content)."\r\n\r\n$content";
        close $client;
    }
    POSIX::_exit(0);
}
close $_ for @listeners;
END {
    if (defined($pid) && $pid > 0 && $$ == $owner) {
        if (waitpid($pid, WNOHANG) == 0) { kill 'TERM', $pid; waitpid($pid, 0) }
    }
}
sub calls_1393 {
    return [] unless -e $log;
    open my $fh, '<:raw', $log or die "read request log: $!";
    my @calls = map { JSON::PP::decode_json($_) } <$fh>;
    close $fh;
    return \@calls;
}
sub since_1393 {
    my ($offset) = @_;
    my $calls = calls_1393();
    return [@$calls[$offset..$#$calls]];
}
sub route_1393 {
    return [map {[@$_{qw(origin method path authorization body_bytes)}]} @{$_[0]}];
}
sub get_1393 {
    my (%options) = @_;
    my $before = scalar @{calls_1393()};
    my $result = Mediabot::External::_make_http(timeout=>2, %options)->get("$first/chain/start");
    return [$result->{status}, route_1393(since_1393($before))];
}
is_deeply(get_1393(max_redirect=>0), [302, [['first','GET','/chain/start',0,0]]],
    'explicit zero stops at the first redirect using the real HTTP transport');
is_deeply(get_1393(max_redirect=>1), [302,
    [['first','GET','/chain/start',0,0],['first','GET','/chain/middle',0,0]]],
    'a positive redirect budget is honored exactly instead of silently using the library default');
is_deeply(get_1393(max_redirect=>2), [200,
    [['first','GET','/chain/start',0,0],['first','GET','/chain/middle',0,0],['first','GET','/finish',0,0]]],
    'an explicitly sufficient budget still follows redirects to a normal response');
{
    my $http = Mediabot::External::_make_http(timeout=>2);
    my $default = HTTP::Tiny->new(timeout=>2)->max_redirect;
    is_deeply([$http->max_redirect == $default ? 1 : 0, get_1393()],
        [1,[200,[['first','GET','/chain/start',0,0],['first','GET','/chain/middle',0,0],['first','GET','/finish',0,0]]]],
        'callers without the option retain the native default and existing redirect behavior');
}
{
    my $before = scalar @{calls_1393()};
    my $result = Mediabot::External::_make_http(timeout=>2,max_redirect=>0)->request(
        'POST', "$first/submit", {headers=>{Authorization=>'Bearer '.('a' x 64)},content=>'fixture'});
    is_deeply([$result->{status},route_1393(since_1393($before))],
        [303,[['first','POST','/submit',1,7]]],
        'a refused POST 303 never contacts the second origin or forwards the supplied authorization header');
}
{
    my $before = scalar @{calls_1393()};
    my $result = Mediabot::External::_make_http(timeout=>2,max_redirect=>0)->request(
        'POST', "$first/post307", {content=>'fixture'});
    is_deeply([$result->{status},route_1393(since_1393($before))],
        [307,[['first','POST','/post307',0,7]]],
        'an unsupported POST redirect still returns its original status without replaying a side effect');
}
{
    my $before = scalar @{calls_1393()};
    local $Mediabot::External::News::TAVILY_URL = "$first/search";
    my $bot = {};
    my $result = Mediabot::External::News::_news_tavily('a' x 64,
        {query=>'fixture',max_results=>1},Time::HiRes::time()+60,$bot);
    my $calls = since_1393($before);
    is_deeply([defined($result) ? 1 : 0,
        [map {[@$_{qw(origin method path authorization)}]} @$calls],
        $calls->[0]{body_bytes} > 0 ? 1 : 0],
        [0,[['first','POST','/search',0]],1],
        'the real news caller now rejects a redirect instead of accepting results fetched at a second endpoint');
}
{
    my $headers = {'accept-language'=>'fr'};
    my $http = Mediabot::External::_make_http(timeout=>2,agent=>'MB1018-fixture',
        max_size=>16,default_headers=>$headers,max_redirect=>0);
    my $result = $http->get("$first/oversized");
    my $compat = Mediabot::External::_make_http(verify_SSL=>0);
    is_deeply([$http->timeout,$http->agent,$http->max_size,$http->default_headers,
        $http->verify_SSL ? 1 : 0,$compat->verify_SSL ? 1 : 0,$result->{status}],
        [2,'MB1018-fixture',16,$headers,1,0,599],
        'timeout, agent, header and TLS policies remain intact and the real response byte limit is still enforced');
}
done_testing;
