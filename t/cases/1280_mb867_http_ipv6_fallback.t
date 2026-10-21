use strict;
use warnings;
use Test::More;
use Mediabot::RSS::Fetcher;
use Mediabot::Plugin::HTTPServiceV3;

{
    package MB867PeerHTTP;
    our (@calls,@constructors,$responses);
    sub get {
        my ($self,$url,$options)=@_;
        push @calls, {url=>$url,%$options};
        my $response=$responses->{$options->{peer}};
        die "transport exception\n" if defined($response) && !ref($response) && $response eq 'throw';
        return $response;
    }
}
my $ipv4='8.8.8.8'; my $ipv4b='1.1.1.1';
my $ipv6='2001:4860:4860::8888'; my $ipv6b='2606:4700:4700::1111';
my $success={success=>1,status=>200,headers=>{},content=>'local fixture'};
my $failed={success=>0,status=>599,headers=>{},content=>'unreachable'};
my $http_error={success=>0,status=>503,headers=>{},content=>'temporarily unavailable'};

for my $service ('Mediabot::RSS::Fetcher','Mediabot::Plugin::HTTPServiceV3') {
    for my $case (
        ['IPv6-only',[$ipv6],{$ipv6=>$success},[$ipv6],200],
        ['IPv4 transport failure',[$ipv6,$ipv4],{$ipv4=>$failed,$ipv6=>$success},[$ipv4,$ipv6],200],
        ['IPv6 transport failure',[$ipv6,$ipv6b],{$ipv6=>$failed,$ipv6b=>$success},[$ipv6,$ipv6b],200],
        ['IPv4 preference',[$ipv6,$ipv4,$ipv4b],{$ipv4=>$success},[$ipv4],200],
        ['HTTP error',[$ipv6,$ipv4],{$ipv4=>$http_error},[$ipv4],503],
        ['transport exception',[$ipv4,$ipv6],{$ipv4=>'throw',$ipv6=>$success},[$ipv4,$ipv6],200],
        ['all peers fail',[$ipv6,$ipv4],{$ipv4=>$failed,$ipv6=>$failed},[$ipv4,$ipv6],599],
    ) {
        my ($label,$peers,$responses,$expected,$status)=@$case;
        my @original_peers=@$peers;
        @MB867PeerHTTP::calls=(); @MB867PeerHTTP::constructors=();
        $MB867PeerHTTP::responses=$responses;
        my ($result,$ok,$error);
        {
            no warnings qw(redefine once);
            local *HTTP::Tiny::new=sub {
                my ($class,%args)=@_; push @MB867PeerHTTP::constructors,\%args;
                return bless {},'MB867PeerHTTP';
            };
            no strict 'refs';
            $ok=eval {$result=&{"${service}::_default_requester"}('https://feed.example.test/rss',
                validated_addresses=>$peers,timeout=>2,max_size=>4096,max_bytes=>4096,accept=>'application/rss+xml');1};
            $error=$@;
        }
        ok($ok,"$service / $label: no exception escapes") or diag($error);
        is(ref($result),'HASH',"$service / $label: returns an HTTP response");
        is($result->{status},$status,"$service / $label: preserves the final status") if ref($result) eq 'HASH';
        is_deeply([map {$_->{peer}} @MB867PeerHTTP::calls],$expected,"$service / $label: uses exactly the admitted peers in the intended order");
        is_deeply($peers,\@original_peers,"$service / $label: caller list remains intact");
        for my $args (@MB867PeerHTTP::constructors) {
            is($args->{verify_SSL},1,"$service / $label: TLS verification stays enabled");
            is($args->{max_redirect},0,"$service / $label: redirects remain caller-validated");
        }
        is($_->{url},'https://feed.example.test/rss',"$service / $label: URL host/SNI identity is preserved") for @MB867PeerHTTP::calls;
    }
}

# Exercise the real validators and transport wrapper, not only peer ordering.
{
    no warnings qw(redefine once);
    local *HTTP::Tiny::new=sub {bless {},'MB867PeerHTTP'};
    @MB867PeerHTTP::calls=();
    $MB867PeerHTTP::responses={$ipv6=>{success=>1,status=>200,headers=>{'content-type'=>'application/rss+xml'},
        content=>'<rss version="2.0"><channel><title>Local</title><item><title>IPv6 item</title><link>https://example.test/item</link></item></channel></rss>'}};
    my $r=Mediabot::RSS::Fetcher::fetch_feed_once('https://feed.example.test/rss',resolver=>sub {[$ipv6]});
    ok($r->{ok},'RSS URL/DNS validation reaches an IPv6-only feed');
    is($r->{feed}{items}[0]{title} // '', 'IPv6 item','RSS parser receives the successful pinned response');
    @MB867PeerHTTP::calls=();
    $MB867PeerHTTP::responses->{$ipv6}=$success;
    my $p=eval {Mediabot::Plugin::HTTPServiceV3::_perform_request(
        \&Mediabot::Plugin::HTTPServiceV3::_default_requester,sub {[$ipv6]},
        'https://feed.example.test/rss',2,4096,'text/plain')};
    ok(ref($p) eq 'HASH' && $p->{ok},'plugin HTTP URL/DNS validation reaches an IPv6-only resource') or diag($@);
    is(ref($p) eq 'HASH' ? $p->{body} : undef,'local fixture','plugin response wrapper retains the returned body');

    @MB867PeerHTTP::calls=();
    my $blocked=Mediabot::RSS::Fetcher::fetch_feed_once('https://feed.example.test/rss',resolver=>sub {['::1']});
    is($blocked->{error},'blocked_destination','RSS still rejects a private IPv6 destination');
    is(scalar @MB867PeerHTTP::calls,0,'RSS never contacts a rejected peer');
    my $ok=eval {Mediabot::Plugin::HTTPServiceV3::_perform_request(
        \&Mediabot::Plugin::HTTPServiceV3::_default_requester,sub {['::1']},
        'https://feed.example.test/rss',2,4096,'text/plain');1};
    ok(!$ok,'plugin HTTP still rejects a private IPv6 destination');
    is(scalar @MB867PeerHTTP::calls,0,'plugin HTTP never contacts a rejected peer');
}

{
    no warnings qw(redefine once);
    local *HTTP::Tiny::new=sub {bless {},'MB867PeerHTTP'};
    @MB867PeerHTTP::calls=();
    my @peers=($ipv6,$ipv6b,$ipv4,$ipv4b,'9.9.9.9');
    $MB867PeerHTTP::responses={map {$_=>$failed} @peers};
    Mediabot::RSS::Fetcher::_default_requester('https://feed.example.test/rss',validated_addresses=>\@peers);
    is_deeply([map {$_->{peer}} @MB867PeerHTTP::calls],[$ipv4,$ipv4b,'9.9.9.9',$ipv6],
        'RSS retains its four-attempt budget after admitting both address families');
}
done_testing;
