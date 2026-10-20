use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::External::URL ();

{ package MB864GateLog; sub log {1} }
sub gate_bot {return {logger=>bless({},'MB864GateLog')}}
my $admit=\&Mediabot::External::URL::_url_display_cache_gate;

# Exercise admission itself: distinct resources must each get their first turn,
# then ordinary repeats must still be suppressed in the same channel.
for my $pair (
    ['https://example.test/Report','https://example.test/report','path'],
    ['https://example.test/?token=AbC','https://example.test/?token=abc','query value'],
    ['https://example.test/?Key=value','https://example.test/?key=value','query name'],
    ['https://example.test/#Part','https://example.test/#part','fragment'],
    ['https://example.test/%2F','https://example.test/%2f','escaped spelling'],
    ['https://example.test/Été','https://example.test/été','Unicode path'],
    ['https://youtube.com/watch?v=AbCdEfGh123','https://youtube.com/watch?v=abcdefgh123','watch ID'],
    ['https://youtu.be/AbCdEfGh123','https://youtu.be/abcdefgh123','short-link ID'],
    ['https://instagram.com/p/AbC123/','https://instagram.com/p/abc123/','post ID'],
    ['https://User:Secret@example.test/a','https://user:secret@example.test/a','userinfo'],
    ['https://[fe80::1%25Scope]/a','https://[fe80::1%25scope]/a','IPv6 scope'],
) {
    my ($first,$second,$kind)=@$pair;my $bot=gate_bot();
    ok($admit->($bot,$first,'#test'),"$kind: first resource is admitted");
    ok($admit->($bot,$second,'#test'),"$kind: case-distinct resource is independently admitted");
    ok(!$admit->($bot,$first,'#test'),"$kind: original resource still cannot repeat");
    ok(!$admit->($bot,$second,'#TEST'),"$kind: second resource also retains channel-scoped suppression");
}
for my $pair (
    ['https://Example.TEST/Report?Token=AbC#Part','HTTPS://EXAMPLE.test/Report?Token=AbC#Part'],
    ['http://example.test:8080/A','HTTP://EXAMPLE.TEST:8080/A'],
    ['https://User:Secret@example.test/A','HTTPS://User:Secret@EXAMPLE.TEST/A'],
    ['https://[2001:db8::ab]:8443/A','HTTPS://[2001:DB8::AB]:8443/A'],
    ['https://[fe80::ab%25Scope]/A','HTTPS://[FE80::AB%25Scope]/A'],
) {
    my $bot=gate_bot();
    ok($admit->($bot,$pair->[0],'#test'),'first scheme/host spelling is admitted');
    ok(!$admit->($bot,$pair->[1],'#TEST'),'scheme/host and channel case alone cannot bypass anti-repeat');
    ok($admit->($bot,$pair->[1],'#i/o'),'another channel retains independent admission');
}
{
    my $bot=gate_bot();my $url='https://example.test/Keep?Value=AbC';
    ok($admit->($bot,$url,'#test'),'TTL fixture is admitted');
    ok($admit->($bot,'http://example.test/Keep?Value=AbC','#test'),'HTTP and HTTPS remain separate');
    ok($admit->($bot,'https://example.test:8443/Keep?Value=AbC','#test'),'explicit port remains separate');
    ok($admit->(gate_bot(),$url,'#test'),'independent bot does not inherit another bot cache');
    $_=time()-601 for values %{$bot->{_url_display_cache}};
    $bot->{_url_cache_last_purge}=time()-120;
    ok($admit->($bot,$url,'#test'),'expired entry is admitted again');
    is(scalar keys %{$bot->{_url_display_cache}},1,'existing periodic purge removes stale entries');
    ok(!$admit->($bot,$url,'#test'),'freshly rearmed entry again suppresses repeats');
}
for my $input (undef, '', 'http://', 'https://:8080') {
    my @warnings;my $ok;
    {local $SIG{__WARN__}=sub {push @warnings,@_};
        $ok=eval {$admit->(gate_bot(),$input,'#test');1}}
    ok($ok && !@warnings,'empty authority/input does not introduce a warning in internal cache bookkeeping');
}
done_testing;
