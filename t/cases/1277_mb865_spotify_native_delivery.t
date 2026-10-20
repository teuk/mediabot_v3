use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use JSON::PP ();
use URI::Escape qw(uri_unescape);
use IO::Async::Loop;
use Time::HiRes ();
use Mediabot::External ();
use Mediabot::External::URL ();

{
    package MB865NativeLog;sub log {1}
    package MB865NativeHTTP;
    sub get {
        my ($self,$url)=@_;
        open my $fh,'>>:raw',$self->{path} or die $!;
        print {$fh} JSON::PP::encode_json({url=>$url}) . "\n" or die $!;close $fh or die $!;
        if ($url =~ m{\Ahttps://open[.]spotify[.]com/oembed\?url=(.*)\z}) {
            my $target=URI::Escape::uri_unescape($1);
            my ($id)=$target =~ m{/track/([A-Za-z0-9]+)\z};die 'unexpected fixture target' unless defined $id;
            return {success=>1,status=>200,content=>JSON::PP::encode_json({title=>"Song $id",author_name=>'Studio'})};
        }
        if ($url =~ m{\Ahttps://open[.]spotify[.]com/embed/track/([A-Za-z0-9]+)\z}) {
            my $id=$1;my $data={props=>{pageProps=>{state=>{data=>{entity=>{
                type=>'track',title=>"Song $id",artists=>[{name=>'Studio'}],
                releaseDate=>{isoString=>'2026-10-20T00:00:00Z'},duration=>62000}}}}}};
            return {success=>1,status=>200,content=>'<script id="__NEXT_DATA__" type="application/json">'.JSON::PP::encode_json($data).'</script>'};
        }
        die 'unexpected external HTTP destination in offline fixture';
    }
}
sub native_bot {return {logger=>bless({},'MB865NativeLog'),out=>[]}}
sub drain865 {
    my ($loop,$bot)=@_;my $deadline=Time::HiRes::time()+8;
    $loop->loop_once(.01) while keys(%{$bot->{_spotify_pending} // {}}) && Time::HiRes::time()<$deadline;
}
sub calls865 {
    my ($path)=@_;open my $fh,'<:raw',$path or die $!;my @calls=map {JSON::PP::decode_json($_)->{url}} <$fh>;close $fh;return \@calls;
}
my ($fh,$path)=tempfile(UNLINK=>1);close $fh;
my $http=bless({path=>$path},'MB865NativeHTTP');our $enabled=1;
no warnings qw(redefine once);
local *Mediabot::External::_make_http=sub {$http};
local *Mediabot::External::_chanset_ok=sub {$enabled};
local *Mediabot::Helpers::botPrivmsg=sub {push @{$_[0]{out}},[$_[1],$_[2]];1};
local *Mediabot::External::_fetch_url_chromium_dumpdom=sub {die 'Spotify must not launch Chromium'};
my $dispatch=\&Mediabot::External::URL::displayUrlTitle;
my $first='AbCdEfGhIjKlMnOpQrSt01';my $second=lc($first);
{
    my $bot=native_bot();my $loop=IO::Async::Loop->really_new;$bot->{loop}=$loop;
    for my $id ($first,$second) {
        ok($dispatch->($bot,undef,'Reader','#test',"https://open.spotify.com/intl-fr/track/$id?si=local"),"real dispatcher accepts native Spotify $id");
    }
    is(scalar keys %{$bot->{_spotify_pending}},2,'native workers own two case-distinct pending requests');
    is(scalar @{$bot->{out}},0,'native requests do not emit before the loop runs');
    $dispatch->($bot,undef,'Waiting','#i/o',"HTTPS://OPEN.SPOTIFY.COM/intl-fr/track/$first?si=other");
    is(scalar keys %{$bot->{_spotify_pending}},2,'same pending resource still coalesces across callers/channels');
    drain865($loop,$bot);
    is(scalar keys %{$bot->{_spotify_pending}},0,'real workers release both pending entries');
    is(scalar @{$bot->{out}},2,'both case-distinct links publish through real worker transport');
    my $lines=join("\n",map {$_->[1]} @{$bot->{out}});
    like($lines,qr/Song \Q$first\E/,'first exact ID survives actual oEmbed/embed parsing and pipe');
    like($lines,qr/Song \Q$second\E/,'second exact ID survives actual oEmbed/embed parsing and pipe');
    is_deeply([map {$_->[0]} @{$bot->{out}}],['#test','#test'],'pending duplicates do not redirect original destination');
    for my $index (0,1) {
        my $line=($bot->{out}[$index] // [])->[1] // '';
        like($line,qr/^\(Reader\).*by Studio.*2026.*1m 02s/,'real rich metadata and original caller remain formatted');
        like($line,qr/Spotify.*\x0f/,'historical badge remains followed by reset');
    }
    my $calls=calls865($path);
    is(scalar @$calls,4,'two resources use two lightweight HTTP calls each');
    for my $id ($first,$second) {
        ok(grep($_ eq "https://open.spotify.com/embed/track/$id",@$calls),'embed receives complete original-case ID');
        ok(grep(URI::Escape::uri_unescape($_) eq "https://open.spotify.com/oembed?url=https://open.spotify.com/intl-fr/track/$id",@$calls),
            'oEmbed receives original clean resource URL without tracking query');
    }
    $dispatch->($bot,undef,'Again','#TEST',"https://open.spotify.com/intl-fr/track/$second?si=local");
    is(scalar @{$bot->{out}},2,'ordinary same-channel anti-repeat still suppresses replay');
    is(scalar keys %{$bot->{_spotify_pending}},0,'suppressed repeat does not start another worker');
    $dispatch->($bot,undef,'Later','#third',"https://open.spotify.com/intl-fr/track/$second");
    is(scalar keys %{$bot->{_spotify_pending}},1,'completed resource can be fetched again for another channel');
    drain865($loop,$bot);
    is(scalar @{$bot->{out}},3,'later admitted request completes normally');
    like($bot->{out}[-1][1],qr/^\(Later\).*Song \Q$second\E/,'later request retains new caller and exact resource');
    is($bot->{out}[-1][0],'#third','later request retains new destination');
    is(scalar @{calls865($path)},6,'later admission retains the existing no-result-cache fetch policy');
}
{
    my $bot=native_bot();$bot->{loop}=IO::Async::Loop->really_new;local $enabled=0;
    my $before=scalar @{calls865($path)};
    $dispatch->($bot,undef,'Reader','#test',"https://open.spotify.com/track/$first");
    is(scalar keys %{$bot->{_spotify_pending} // {}},0,'disabled UrlTitle starts no Spotify worker');
    is(scalar keys %{$bot->{_url_display_cache} // {}},0,'disabled feature does not consume repeat admission');
    is(scalar @{calls865($path)},$before,'disabled feature makes no HTTP request');
    $enabled=1;
    ok($dispatch->($bot,undef,'Reader','#test',"https://open.spotify.com/track/$first"),'enabling allows the same URL immediately');
    drain865($bot->{loop},$bot);
    is(scalar @{$bot->{out}},1,'enabled request completes via actual worker');
}
done_testing;
