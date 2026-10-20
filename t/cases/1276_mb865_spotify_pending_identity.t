use strict;
use warnings;
use Test::More;
use Mediabot::External ();

{
    package MB865Log;sub log {1}
    package MB865Loop;sub add {1}sub remove {1}sub watch_process {1}
}
sub pending_bot {return {logger=>bless({},'MB865Log'),loop=>bless({},'MB865Loop'),out=>[]}}
my $handle=\&Mediabot::External::_handle_spotify;
my $first='AbCdEfGhIjKlMnOpQrSt01';my $second=lc($first);
my @jobs;
no warnings qw(redefine once);
local *Mediabot::AsyncWorker::start=sub {my ($class,%args)=@_;push @jobs,\%args;return bless {},'MB865Worker'};
local *Mediabot::Helpers::botPrivmsg=sub {push @{$_[0]{out}},[$_[1],$_[2]];1};

for my $type (qw(track album playlist episode show artist)) {
    my $bot=pending_bot();@jobs=();
    my $url="https://open.spotify.com/$type/$first";
    ok($handle->($bot,undef,'First','#test',$url),"$type: first request launches");
    ok($handle->($bot,undef,'Second','#i/o',"https://open.spotify.com/$type/$second"),"$type: case-distinct request is accepted");
    is(scalar @jobs,2,"$type: each resource gets its own worker");
    is(scalar keys %{$bot->{_spotify_pending}},2,"$type: pending ownership keeps resource case");
    is(scalar @{$bot->{out}},0,"$type: admission performs no premature delivery");
    $handle->($bot,undef,'Waiting','#other',"HTTPS://OPEN.SPOTIFY.COM/$type/$first?si=another");
    is(scalar @jobs,2,"$type: matching host/scheme spelling and stripped tracking query still coalesce");

    # Finish the second resource first. A missing job on the old source must
    # fail assertions without aborting the remainder of the reproduction.
    $jobs[1]{on_done}->({ok=>1,value=>{title=>"Song $second",artist=>'Studio'}}) if $jobs[1];
    is(scalar keys %{$bot->{_spotify_pending}},1,"$type: second completion leaves first pending");
    like(($bot->{out}[0] // [])->[1] // '',qr/^\(Second\).*Song \Q$second\E/,"$type: out-of-order result retains its caller and identity");
    is(($bot->{out}[0] // [])->[0],'#i/o',"$type: out-of-order result keeps its channel");
    $jobs[0]{on_done}->({ok=>1,value=>{title=>"Song $first",artist=>'Studio'}});
    is(scalar keys %{$bot->{_spotify_pending}},0,"$type: both completions release pending capacity");
    is(scalar @{$bot->{out}},2,"$type: both resources publish once");
    like($bot->{out}[-1][1],qr/^\(First\).*Song \Q$first\E/,"$type: first request keeps its own result");
    $jobs[0]{on_done}->({ok=>1,value=>{title=>'obsolete duplicate'}});
    is(scalar @{$bot->{out}},2,"$type: retained completion cannot publish twice");
}
{
    my $bot=pending_bot();@jobs=();
    $handle->($bot,undef,'First','#test',"https://open.spotify.com/track/$first");
    $handle->($bot,undef,'Second','#i/o',"https://open.spotify.com/track/$second");
    $jobs[0]{on_done}->({ok=>0,error=>'worker_timeout'});
    is(scalar keys %{$bot->{_spotify_pending}},1,'one failed resource preserves the other pending request');
    is(scalar @{$bot->{out}},0,'failed metadata does not publish a success');
    $handle->($bot,undef,'Retry','#retry',"https://open.spotify.com/track/$first");
    is(scalar @jobs,3,'failed resource can immediately obtain a new worker');
    $jobs[1]{on_done}->({ok=>1,value=>{title=>"Song $second"}}) if $jobs[1];
    $jobs[2]{on_done}->({ok=>1,value=>{title=>"Song $first"}}) if $jobs[2];
    is(scalar keys %{$bot->{_spotify_pending}},0,'sibling and retry release their own pending entries');
    is_deeply([map {$_->[0]} @{$bot->{out}}],['#i/o','#retry'],'sibling and retry retain independent destinations');
}
for my $failure (qw(refuse throw)) {
    my $bot=pending_bot();my $attempts=0;
    local *Mediabot::AsyncWorker::start=sub {
        my ($class,%args)=@_;$attempts++;
        if ($attempts==1) {die 'local setup failure' if $failure eq 'throw';return undef}
        push @jobs,\%args;return bless {},'MB865Worker';
    };
    @jobs=();
    ok($handle->($bot,undef,'First','#test',"https://open.spotify.com/track/$first"),"$failure: existing setup failure boundary remains contained");
    is(scalar keys %{$bot->{_spotify_pending}},0,"$failure: failed launch releases admission");
    is(scalar @{$bot->{out}},0,"$failure: no title is invented");
    $handle->($bot,undef,'Retry','#retry',"https://open.spotify.com/track/$first");
    is($attempts,2,"$failure: later request can retry");
    $jobs[0]{on_done}->({ok=>1,value=>{title=>'Recovered'}});
    is(scalar keys %{$bot->{_spotify_pending}},0,"$failure: successful retry cleans pending state");
    like($bot->{out}[0][1],qr/^\(Retry\).*Recovered/,"$failure: retry retains ordinary delivery");
}
done_testing;
