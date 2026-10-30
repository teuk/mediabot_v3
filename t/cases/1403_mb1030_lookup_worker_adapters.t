use strict;
use warnings;
use utf8;
use Test::More;
use Scalar::Util qw(refaddr weaken);
use Mediabot::Helpers ();
use Mediabot::UserCommands ();
use Mediabot::AsyncWorker ();

binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
{
    package MB1030::Loop;
    sub add {1} sub remove {1}
    package MB1030::Bot;
    sub getLoop {$_[0]{loop}}
    package MB1030::Log;
    sub log {die "broken logger\n"}
}
my @warnings;
local $SIG{__WARN__}=sub {push @warnings,@_};
no warnings qw(redefine once);
is(refaddr(Mediabot::UserCommands->can('_define_lookup_async')),
    refaddr(Mediabot::External::Wiktionary->can('_define_lookup_async')),
    'historical define entry point aliases its domain owner instead of duplicating orchestration');

sub invoke_1403 {
    my ($kind,$bot,$done,%opts)=@_;
    return Mediabot::Helpers::whereis_async($bot,'host.invalid',$done,%opts) if $kind eq 'country';
    return Mediabot::UserCommands::_define_lookup_async($bot,'café','fr',$done,%opts);
}
sub fallback_1403 {$_[0] eq 'country'?'N/A':"define: could not fetch definition for 'café'."}
my $bot=bless {loop=>bless({},'MB1030::Loop')},'MB1030::Bot';
{
    my (@jobs,@source);
    local *Mediabot::Helpers::whereis=sub {push @source,['country',@_];' FR '};
    local *Mediabot::UserCommands::_define_lookup_sync=sub {push @source,['define',@_];'définition'};
    local *Mediabot::AsyncWorker::start=sub {my ($class,%a)=@_;push @jobs,\%a;bless {},'MB1030::Worker'};
    my (@actual,@got);
    for my $kind (qw(country define)) {
        my $ret=invoke_1403($kind,$bot,sub {push @got,shift});
        my $job=$jobs[-1];my $value=$job->{child}->();
        $job->{on_done}->({ok=>1,value=>$value});
        push @actual,[$ret,$job->{label},$job->{timeout},$job->{term_grace},$job->{max_output},
            $got[-1],scalar(keys %{$source[-1][1]}),[@{$source[-1]}[2..$#{$source[-1]}]]];
    }
    is_deeply(\@actual,[
        [1,'country lookup',5,0.2,1024,'FR',0,['host.invalid']],
        [1,'definition lookup',10,0.2,8192,'définition',0,['café','fr']],
    ],'both adapters delegate bounded work to the shared owner and pass only lookup inputs into empty child bot state');
}
{
    my (@actual,$source_calls);
    local *Mediabot::Helpers::whereis=sub {$source_calls++;'FR'};
    local *Mediabot::UserCommands::_define_lookup_sync=sub {$source_calls++;'definition'};
    for my $kind (qw(country define)) {
        for my $mode (qw(die undef done-undef done-die)) {
            my @got;
            local *Mediabot::AsyncWorker::start=sub {
                my ($class,%a)=@_;
                $a{on_done}->({ok=>1,value=>{$kind eq 'country'?'country':'message'=>'accepted'}})
                    if $mode=~/^done/;
                die "launch exception\n" if $mode=~/die$/;
                return undef;
            };
            my $ret=invoke_1403($kind,$bot,sub {push @got,shift});
            push @actual,[$ret,\@got];
        }
    }
    is_deeply([\@actual,$source_calls//0],[[map {
        my $kind=$_;map {[1,[$_=~/^done/?'accepted':fallback_1403($kind)]]} qw(die undef done-undef done-die)
    } qw(country define)],0],
        'launch failure and synchronous completion deliver once without ever retrying a blocking source in the parent');
}
{
    my @actual;
    for my $kind (qw(country define)) {
        my $key=$kind eq 'country'?'country':'message';my $limit=$kind eq 'country'?128:1024;
        for my $result ({ok=>0},undef,{ok=>1,value=>[]},{ok=>1,value=>{$key=>[]}},
                {ok=>1,value=>{$key=>''}},{ok=>1,value=>{$key=>'x'x($limit+1)}}) {
            my ($job,@got);
            local *Mediabot::AsyncWorker::start=sub {my ($class,%a)=@_;$job=\%a;bless {},'MB1030::Worker'};
            invoke_1403($kind,$bot,sub {push @got,shift});
            $job->{on_done}->($result);$job->{on_done}->({ok=>1,value=>{$key=>'late'}});
            push @actual,\@got;
        }
    }
    is_deeply(\@actual,[map {my $kind=$_;map {[fallback_1403($kind)]} 1..6} qw(country define)],
        'worker failures and malformed or excessive values keep provider-specific fallbacks and ignore late duplicate completion');
}
{
    my (@actual,@jobs);
    local *Mediabot::AsyncWorker::start=sub {my ($class,%a)=@_;push @jobs,\%a;bless {},'MB1030::Worker'};
    for my $kind (qw(country define)) {
        my $key=$kind eq 'country'?'country':'message';my @got;
        invoke_1403($kind,$bot,sub {
            push @got,shift;
            invoke_1403($kind,$bot,sub {push @got,shift});
        });
        my $old=$jobs[-1];$old->{on_done}->({ok=>1,value=>{$key=>'first'}});
        $old->{on_done}->({ok=>1,value=>{$key=>'stale'}});
        $jobs[-1]{on_done}->({ok=>1,value=>{$key=>'second'}});
        push @actual,\@got;
    }
    is_deeply(\@actual,[['first','second'],['first','second']],
        'a callback can start a fresh lookup without a retained old completion crossing request boundaries');
}
{
    my @released;
    for my $kind (qw(country define)) {
        my ($job,$weak);
        local *Mediabot::AsyncWorker::start=sub {my ($class,%a)=@_;$job=\%a;bless {},'MB1030::Worker'};
        {
            my $payload=bless {},'MB1030::Payload';$weak=$payload;weaken($weak);
            invoke_1403($kind,$bot,sub {my $held=$payload;1});
        }
        $job->{on_done}->({ok=>0});
        push @released,defined($weak)?0:1;
    }
    is_deeply(\@released,[1,1],
        'completed adapters release caller payloads even if the worker retains its completion callback');
}
{
    my @actual;my $broken=bless {loop=>$bot->{loop},logger=>bless({},'MB1030::Log')},'MB1030::Bot';
    local *Mediabot::AsyncWorker::start=sub {my ($class,%a)=@_;$a{on_done}->({ok=>0});undef};
    for my $kind (qw(country define)) {
        my $calls=0;my $ok=eval {invoke_1403($kind,$broken,sub {$calls++;die "consumer exception\n"});1};
        push @actual,[$ok?1:0,$calls];
    }
    is_deeply(\@actual,[[1,1],[1,1]],'a failed consumer and failed logger cannot escape into the event loop or trigger a second delivery');
}
{
    my ($launches,@actual);
    local *Mediabot::AsyncWorker::start=sub {$launches++;die 'unexpected async worker'};
    for my $kind (qw(country define)) {
        for my $value ('legacy',undef,[], 'exception') {
            my $lookup=sub {die "source exception\n" if defined($value) && !ref($value) && $value eq 'exception';$value};
            local *Mediabot::Helpers::whereis=$lookup;
            local *Mediabot::UserCommands::_define_lookup_sync=$lookup;
            my @got;my $ret=invoke_1403($kind,{},sub {push @got,shift});
            push @actual,[$ret,\@got];
        }
        push @actual,[invoke_1403($kind,$bot,'invalid callback')];
    }
    is_deeply([\@actual,$launches//0],[[map {
        my $kind=$_;([1,['legacy']],(map {[1,[fallback_1403($kind)]]} 1..3),[0])
    } qw(country define)],0], 'no-loop compatibility and invalid-callback handling remain explicit and never allocate a worker');
}
{
    require IO::Async::Loop;
    require IO::Async::Timer::Countdown;
    require Time::HiRes;
    require POSIX;
    my $loop=IO::Async::Loop->new;my $native=bless {loop=>$loop},'MB1030::Bot';
    my (@workers,@got,@ticks);my $start=Mediabot::AsyncWorker->can('start');
    my $country='Réunion';my $definition=('café : scène 🎛️ ' x 100);
    local *Mediabot::Helpers::whereis=sub {select undef,undef,undef,0.08;$country};
    local *Mediabot::UserCommands::_define_lookup_sync=sub {select undef,undef,undef,0.08;$definition};
    local *Mediabot::AsyncWorker::start=sub {my $w=$start->(@_);push @workers,$w;$w};
    my $heartbeat=IO::Async::Timer::Countdown->new(delay=>0.02,on_expire=>sub {push @ticks,1});
    $loop->add($heartbeat);$heartbeat->start;
    invoke_1403('country',$native,sub {push @got,['country',shift]});
    invoke_1403('define',$native,sub {push @got,['define',shift]});
    my $deadline=Time::HiRes::time()+3;
    $loop->loop_once(0.02) while @got<2 && Time::HiRes::time()<$deadline;
    $loop->loop_once(0.01) for 1..3;
    is_deeply([sort {$a->[0] cmp $b->[0]} @got],
        [['country',$country],['define',substr($definition,0,1024)]],
        'real shared fork/pipe protocol preserves Unicode and provider text bounds');
    is_deeply([scalar(@ticks),map {[$_->is_done,waitpid($_->pid,POSIX::WNOHANG())]} @workers],
        [1,[1,-1],[1,-1]],'native lookups leave the heartbeat responsive and both children collected');
}
is_deeply(\@warnings,[],'lookup adaptation and native completion produce no warnings');
done_testing;
