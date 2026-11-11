use strict;
use warnings;
use Test::More;
use Scalar::Util qw(refaddr weaken);
use Mediabot::IRC::Timer qw(countdown cancel_countdown);
BEGIN { $INC{'IO/Async/Timer/Countdown.pm'} = __FILE__ }
{
    package IO::Async::Timer::Countdown;
    sub new { my ($class,%args)=@_; bless \%args,$class }
    sub start { $_[0]{starts}++; 1 }
    sub stop { $_[0]{stops}++; 1 }
    package MB1146::Loop;
    sub new { bless {attached=>{},callbacks=>[],starts=>0},shift }
    sub add {
        my ($self,$timer)=@_;
        $self->{attached}{Scalar::Util::refaddr($timer)}=$timer;
        push @{$self->{callbacks}},$timer->{on_expire};
        $self->{probe}=$timer; Scalar::Util::weaken($self->{probe});
        $timer->{on_expire}->($timer,'inline') unless $self->{deferred};
        die $self->{error} if $self->{error};
        return $timer;
    }
    sub remove { delete $_[0]{attached}{Scalar::Util::refaddr($_[1])}; 1 }
}
for my $mode (qw(success callback_error add_error)) {
    my $loop=MB1146::Loop->new;
    my $error=bless {},'MB1146::Error';
    $loop->{error}=$error if $mode eq 'add_error';
    my ($calls,$returned)=(0);
    my $ok=eval {
        $returned=countdown(loop=>$loop,delay=>0,on_expire=>sub {
            my ($timer,$marker)=@_;++$calls;
            is($marker,'inline','expiry arguments forwarded');
            is(scalar keys %{$loop->{attached}},0,'timer removed before consumer runs');
            is($timer->{stops},1,'expired timer stopped once');
            die $error if $mode eq 'callback_error';
        }); 1;
    };
    my $caught=$@;
    if ($mode eq 'success') {
        ok($ok,'expiry during add succeeds without starting an undefined timer');
        is($returned,undef,'already completed timer is not returned as live');
    } else {
        ok(!$ok,'original setup or callback failure propagates');
        is(refaddr($caught),refaddr($error),'exception identity retained');
    }
    is($calls,1,'consumer invoked once');
    is(scalar keys %{$loop->{attached}},0,'no expired notifier remains attached');
    ok(!defined $loop->{probe},'expired notifier is released');
    $loop->{callbacks}[0]->();
    is($calls,1,'late callback stays inert');
}
{
    my $loop=MB1146::Loop->new;my $successor;
    my $ok=eval { countdown(loop=>$loop,delay=>0,on_expire=>sub {
        $loop->{deferred}=1;
        $successor=countdown(loop=>$loop,delay=>1,on_expire=>sub{});
    });1 };
    ok($ok,'inline callback can schedule a successor');
    is($successor->{starts},1,'successor started exactly once');
    is(scalar keys %{$loop->{attached}},1,'successor remains attached');
    $successor->{on_expire}->();
    is(scalar keys %{$loop->{attached}},0,'successor cleans up independently');
}
# MB1212: cancellation revokes before any reentrant cleanup and releases payload.
for my $fault ('', 'stop', 'remove', 'both') {
    my $loop=MB1146::Loop->new;$loop->{deferred}=1;
    my ($stops,$removes,$calls)=(0,0,0);
    my $owner=bless {},'MB1212::Payload';my $weak=$owner;weaken($weak);
    my $timer=countdown(loop=>$loop,delay=>100,on_expire=>(sub {
        my($held)=@_;return sub {$calls++ if $held};
    })->($owner));
    undef $owner;
    my $callback=$timer->{on_expire};
    no warnings 'redefine';
    local *IO::Async::Timer::Countdown::stop=sub {
        $stops++;$callback->();
        die "stop fault\n" if $fault eq 'stop' || $fault eq 'both';1;
    };
    local *MB1146::Loop::remove=sub {
        $removes++;$callback->();
        die "remove fault\n" if $fault eq 'remove' || $fault eq 'both';
        delete $_[0]{attached}{refaddr($_[1])};1;
    };
    is(cancel_countdown($timer),$fault eq ''?1:0,'cancellation reports physical cleanup failure');
    is_deeply([$stops,$removes,$calls],[1,1,0],'both cleanup operations run and reentrant expiry is inert');
    ok(!defined $weak,'cancellation releases payload even when callback is retained');
    is(cancel_countdown($timer),1,'repeated cancellation is inert');
    $callback->();
    is_deeply([$stops,$removes,$calls],[1,1,0],'late callback and repeat do not run cleanup or user code twice');
}
{
    my $loop=MB1146::Loop->new;$loop->{deferred}=1;
    my ($timer,$successor);
    $timer=countdown(loop=>$loop,delay=>100,on_expire=>sub {fail('cancelled callback ran')});
    my $stop=IO::Async::Timer::Countdown->can('stop');
    no warnings 'redefine';
    local *IO::Async::Timer::Countdown::stop=sub {
        is(cancel_countdown($timer),1,'nested cancellation is already revoked');
        $successor=countdown(loop=>$loop,delay=>100,on_expire=>sub {});
        $stop->(@_);
    };
    is(cancel_countdown($timer),1,'reentrant cleanup completes');
    is(scalar keys %{$loop->{attached}},1,'reentrant successor is retained');
    is($successor->{starts},1,'successor remains scheduled once');
}
{
    my $loop=MB1146::Loop->new;$loop->{deferred}=1;
    no warnings 'redefine';
    my $add=MB1146::Loop->can('add');
    local *MB1146::Loop::add=sub {$add->(@_);cancel_countdown($_[1])};
    my $timer=countdown(loop=>$loop,delay=>100,on_expire=>sub {fail('inline cancelled callback ran')});
    is($timer,undef,'cancellation during add returns no live timer');
    is(scalar keys %{$loop->{attached}},0,'inline cancellation removes timer without starting it');
    $loop->{callbacks}[0]->();
}
done_testing;
