use strict;
use warnings;
use Test::More;
use Scalar::Util qw(weaken refaddr);
use IO::Async::Loop;
use IO::Async::Timer::Countdown;
use Mediabot::IRC::Timer qw(countdown cancel_countdown);
use Mediabot::IRC::PacedOutput qw(queue_notices queue_privmsg_chunks);
use Mediabot::IRC::Output qw(privmsg action);
use MB881OutputFixture;
use Mediabot::UserCommands ();
use Mediabot::Mediabot ();

sub timer_count {scalar grep {$_->isa('IO::Async::Timer::Countdown')} $_[0]->notifiers}
no warnings qw(redefine once);
{
    my $loop = IO::Async::Loop->really_new;
    my $owner = bless {}, 'MB882::NativeOwner';
    my $weak_owner = $owner; weaken($weak_owner);
    my $calls = 0;
    my $timer = countdown(loop => $loop, delay => 0, on_expire => (sub {my ($held) = @_; return sub {$calls++ if $held}})->($owner));
    my $weak_timer = $timer; weaken($weak_timer);
    my $callback = $timer->{on_expire};
    undef $timer;
    $loop->loop_once(0.01);
    undef $owner;
    my @completed=($calls,timer_count($loop),defined($weak_timer)?1:0,defined($weak_owner)?1:0);
    $callback->();
    is_deeply([@completed,$calls],[1,0,0,0,1],
        'native loop owns the pending timer, expires it once, frees timer/payload and leaves retained expiry inert');
}
for my $stage (qw(add-after start)) {
    my $loop = IO::Async::Loop->really_new;
    my $error = bless {}, 'MB882::NativeError';
    my $original_add = $loop->can('add');
    my $original_start = IO::Async::Timer::Countdown->can('start');
    my ($callback, $probe);
    local *IO::Async::Loop::add = sub {
        my ($l, $timer) = @_;
        my $result = $original_add->(@_);
        $callback = $timer->{on_expire}; $probe = $timer; weaken($probe);
        die $error if $stage eq 'add-after';
        $result;
    };
    local *IO::Async::Timer::Countdown::start = sub {die $error if $stage eq 'start'; $original_start->(@_)};
    my $owner = bless {}, 'MB882::NativeOwner'; my $weak_owner = $owner; weaken($weak_owner);
    my $calls = 0;
    my $ok = eval {countdown(loop => $loop, delay => 0, on_expire => (sub {my ($held) = @_; return sub {$calls++ if $held}})->($owner)); 1};
    my $got = $@;
    undef $owner;
    $callback->();
    is_deeply([!$ok && refaddr($got)==refaddr($error)?1:0,timer_count($loop),
        defined($probe)?1:0,defined($weak_owner)?1:0,$calls],[1,0,0,0,0],
        "$stage: native setup preserves the exception, detaches/frees the notifier and releases payload before an inert late callback");
}

# MB1081: real early removal must release a never-fired notifier and payload.
# No retained callback or payload-created timer reference is part of this case.
{
    my $loop=IO::Async::Loop->really_new;my $weak_loop=$loop;weaken($weak_loop);
    my (@states,$calls);$calls=0;
    for (1..24) {
        my $payload=bless {},'MB1081::Payload';my $weak_payload=$payload;weaken($weak_payload);
        my $timer=countdown(loop=>$loop,delay=>3600,
            on_expire=>(sub {my $held=shift;return sub {$calls++ if $held}})->($payload));
        my $probe=$timer;weaken($probe);undef $payload;
        my @active=(timer_count($loop),$timer->is_running?1:0,defined($weak_payload)?1:0);
        $timer->stop;$loop->remove($timer);undef $timer;
        push @states,[@active,timer_count($loop),defined($probe)?1:0,defined($weak_payload)?1:0];
    }
    undef $loop;
    is_deeply([\@states,$calls,defined($weak_loop)?1:0],
        [[map {[1,1,1,0,0,0]} 1..24],0,0],
        'MB1081: repeated native stop/remove frees unexpired notifiers, payloads and the loop without running user callbacks');
}
{
    my $start=IO::Async::Timer::Countdown->can('start');my @states;
    for my $throws (0,1) {
        my $loop=IO::Async::Loop->really_new;
        my $payload={};my $weak_payload=$payload;weaken($weak_payload);
        my $error=bless {},'MB1081::InlineError';my ($probe,$calls);$calls=0;
        local *IO::Async::Timer::Countdown::start=sub {
            my $self=shift;$probe=$self;weaken($probe);
            my $rv=$start->($self,@_);
            $self->{on_expire}->($self); # native notifier, inline expiry seam
            die $error if $throws;
            return $rv;
        };
        my $result;
        my $ok=eval {$result=countdown(loop=>$loop,delay=>0,
            on_expire=>(sub {my $held=shift;return sub {$calls++ if $held}})->($payload));1};
        my $got=$@;undef $payload;
        push @states,[$ok?1:0,defined($result)?1:0,$calls,timer_count($loop),
            defined($probe)?1:0,defined($weak_payload)?1:0,
            $throws && refaddr($got)==refaddr($error)?1:0];
    }
    is_deeply(\@states,[[1,0,1,0,0,0,0],[0,0,1,0,0,0,1]],
        'MB1081: inline expiry stays single-use and a subsequent start exception retains its original object after cleanup');
}
my $original_new = IO::Async::Timer::Countdown->can('new');
# Exercise production callbacks with real native timers, without waiting for
# the production delays already asserted by deterministic tests.
local *IO::Async::Timer::Countdown::new = sub {
    my ($class, %args) = @_; $args{delay} = 0; $original_new->($class, %args);
};
MB881OutputFixture::with_policy(sub {
    my $bot = MB881OutputFixture::new_bot(); $bot->{loop} = IO::Async::Loop->really_new;
    $bot->{policy}{AntiFlood} = 1;
    my @states;
    for my $i (1 .. 6) {
        $bot->{blocked} = 1;
        $i % 2 ? privmsg($bot, '#test', "item$i") : action($bot, '#test', "item$i");
        my $armed=timer_count($bot->{loop});
        $bot->{blocked} = 0;
        $bot->{loop}->loop_once(0.01);
        push @states,[$armed,timer_count($bot->{loop})];
    }
    is_deeply(\@states,[[1,0],[1,0],[1,0],[1,0],[1,0],[1,0]],
        'native AntiFlood owns exactly one notifier per arm and detaches it after every mixed output round');
    is_deeply([[map {$_->{text}} @{$bot->{irc}{wire}}],$bot->{_flood_outq}{'#test'}{armed}],
        [[map {$_ % 2 ? "item$_" : "\1ACTION item$_\1"} 1 .. 6],0],
        'native mixed messages preserve exact count/order, ACTION envelopes and the final cleared arm');
});
{
    my $bot = MB881OutputFixture::new_bot(); $bot->{loop} = IO::Async::Loop->really_new;
    my @wire; my $error = bless {}, 'MB882::NativeNoticeError';
    local *Mediabot::Helpers::botNotice = sub {die $error if $_[2] eq 'fail'; push @wire, $_[2]; 1};
    queue_notices($bot, 'nick', 'fail');
    my ($timer) = $bot->{loop}->notifiers;
    my $callback = $timer->{on_expire}; my $probe = $timer; weaken($probe); undef $timer;
    my $ok = eval {$bot->{loop}->loop_once(0.01); 1}; my $got = $@;
    ok(!$ok && refaddr($got) == refaddr($error), 'native NOTICE transport exception is preserved');
    is(timer_count($bot->{loop}), 0, 'native failed NOTICE leaves no notifier');
    is_deeply($bot->{_notice_queue_timers}, [], 'native failed NOTICE leaves no queue slot');
    ok(!defined $probe, 'native failed NOTICE timer is freed');
    $callback->();
    is_deeply(\@wire, [], 'retained failed NOTICE expiry cannot resend');
    queue_notices($bot, 'nick', 'recovered'); $bot->{loop}->loop_once(0.01);
    is_deeply(\@wire, ['recovered'], 'a later native NOTICE still works');
    is(timer_count($bot->{loop}), 0, 'later native NOTICE also cleans up');
}
{
    my $bot = MB881OutputFixture::new_bot(); $bot->{loop} = IO::Async::Loop->really_new;
    my @wire;
    local *Mediabot::Helpers::botPrivmsg = sub {push @wire, $_[2]; 1};
    queue_privmsg_chunks($bot, '#test', [qw(one two)], 10_000);
    $bot->{loop}->loop_once(0.01);
    is_deeply([\@wire,$bot->{_external_ai_output_queues},timer_count($bot->{loop})],
        [[qw(one two)],{},0], 'native paced PRIVMSG completes its batch and releases queue state and notifier');
}
# MB1094: send diagnostics must not strand the paced pump. Use actual loop
# occurrences; shorten only delays through the existing native timer seam.
our ($bool_calls_1094,$string_calls_1094)=(0,0);
{
    package MB1094::StringError;
    use overload 'bool'=>sub {$main::bool_calls_1094++;1},
        '""'=>sub {$main::string_calls_1094++;die "private exception formatter failed\n"},fallback=>1;
    package MB1094::BoolError;
    use overload 'bool'=>sub {$main::bool_calls_1094++;die "private exception boolean failed\n"},
        '""'=>sub {$main::string_calls_1094++;die "private exception formatter failed\n"},fallback=>1;
    package MB1094::FalseError;
    use overload 'bool'=>sub {$main::bool_calls_1094++;0},
        '""'=>sub {$main::string_calls_1094++;'private exception payload'},fallback=>1;
    package MB1094::Logger;
    sub log {
        push @{$_[0]{rows}},$_[2];
        die bless({},'MB1094::BoolError') if $_[0]{broken};
        return 1;
    }
}
{
    my (@bad_flow,@bad_diagnostic,@bad_cleanup,@warnings);
    local $SIG{__WARN__}=sub {push @warnings,@_};
    for my $type (qw(scalar long MB1094::StringError MB1094::BoolError MB1094::FalseError)) {
        for my $phase (qw(first middle last)) {
            for my $logging (qw(normal broken absent)) {
                $bool_calls_1094=$string_calls_1094=0;
                my $error=$type eq 'scalar'?"known\nfailure\n":$type eq 'long'?('x'x3000)."\n":bless({},$type);
                my $bot=MB881OutputFixture::new_bot();$bot->{loop}=IO::Async::Loop->really_new;
                my $logger=$logging eq 'absent'?undef:bless({rows=>[],broken=>$logging eq 'broken'},'MB1094::Logger');
                $bot->{logger}=$logger;
                my (@attempted,@wire,@healthy,@counts);my $escaped=0;
                local *Mediabot::Helpers::botPrivmsg=sub {
                    my (undef,$target,$text)=@_;
                    if ($target eq '#test') {
                        push @attempted,$text;
                        die $error if $text eq 'fail';
                        push @wire,$text;
                    } else {push @healthy,$text}
                    return 1;
                };
                my @payload=$phase eq 'first'?qw(fail one two):$phase eq 'middle'?qw(one fail two):qw(one two fail);
                my $owner=bless {},'MB1094::Payload';my $weak_owner=$owner;weaken($weak_owner);
                my $guard=(sub {my $held=shift;return sub {$held?1:0}})->($owner);
                my $ok=eval {push @counts,queue_privmsg_chunks($bot,'#test',\@payload,10_000,'fixture',{can_send=>$guard});1};
                $escaped++ unless $ok;
                undef $guard;undef $owner;
                $ok=eval {
                    push @counts,queue_privmsg_chunks($bot,'#test',[qw(successor tail)],10_000);
                    push @counts,queue_privmsg_chunks($bot,'#test',['late'],0);
                    queue_privmsg_chunks($bot,'#other',[qw(healthy-one healthy-two)],10_000);
                    1;
                };
                $escaped++ unless $ok;
                for (1..16) {
                    last unless timer_count($bot->{loop});
                    $ok=eval {$bot->{loop}->loop_once(0);1};
                    $escaped++ unless $ok;
                }
                my $label="$type/$phase/$logging";
                my $sequence=join('|',@payload,qw(successor tail late));
                my $delivered=join('|',(grep {$_ ne 'fail'} @payload),qw(successor tail late));
                push @bad_flow,$label if $escaped || join('|',@attempted) ne $sequence
                    || join('|',@wire) ne $delivered || join('|',@healthy) ne 'healthy-one|healthy-two'
                    || join('|',@counts) ne '3|2|1';
                my $expected='fixture paced output failed for #test: '.
                    ($type eq 'scalar'?'known failure ':$type eq 'long'?('x'x512):'non-scalar send exception');
                my @logs=$logger?@{$logger->{rows}}:();
                push @bad_diagnostic,$label if $bool_calls_1094 || $string_calls_1094
                    || ($logging eq 'absent'?@logs!=0:@logs!=1 || $logs[0] ne $expected);
                push @bad_cleanup,$label if timer_count($bot->{loop})
                    || keys(%{$bot->{_external_ai_output_queues}}) || defined($weak_owner);
            }
        }
    }
    is_deeply(\@bad_flow,[],
        'MB1094: native paced failures never escape or strand current/successor batches, replay uncertain sends or affect another target');
    is_deeply(\@bad_diagnostic,[],
        'MB1094: scalar diagnostics stay bounded and objects never invoke overloads, including a failing or absent logger');
    is_deeply([\@bad_cleanup,\@warnings],[[],[]],
        'MB1094: every native failure path releases queues, notifiers and guarded payloads without warnings');
}
{
    my @bad;
    for my $class (qw(MB1094::StringError MB1094::BoolError MB1094::FalseError)) {
        $bool_calls_1094=$string_calls_1094=0;
        my $error=bless {},$class;my $bot=MB881OutputFixture::new_bot();
        local *Mediabot::Helpers::botPrivmsg=sub {die $error};
        my $ok=eval {queue_privmsg_chunks($bot,'#test',['fail'],0);1};my $caught=$@;
        push @bad,$class if $ok || !ref($caught) || refaddr($caught)!=refaddr($error)
            || $bool_calls_1094 || $string_calls_1094 || exists($bot->{_external_ai_output_queues});
    }
    is_deeply(\@bad,[],
        'MB1094: immediate no-loop output still propagates the original exception object without queue state');
}

sub quotegame_fixture {
    my $bot = MB881OutputFixture::new_bot();
    $bot->{loop} = IO::Async::Loop->really_new;
    my $round = $bot->{_quotegame}{'#test'} = {
        active => 1, author => 'Author', deadline => 0, token => 'round',
    };
    return ($bot, $round, $bot->{loop});
}
{
    my ($bot, $round, $loop) = quotegame_fixture();
    Mediabot::UserCommands::_quotegame_start_timer($bot, '#test', 'round', 60);
    my $probe = $round->{timer}; weaken($probe);
    $bot->{loop} = IO::Async::Loop->really_new;
    Mediabot::UserCommands::_quotegame_cancel_timer($bot, '#test');
    is_deeply([timer_count($loop), defined($probe) ? 1 : 0], [0,0],
        'cancelling a quote timer detaches it from its owning loop and frees the notifier');
}
{
    my ($bot, $round, $loop) = quotegame_fixture();
    my @wire;
    local *Mediabot::Helpers::botPrivmsg = sub {push @wire, $_[2]; 1};
    Mediabot::UserCommands::_quotegame_start_timer($bot, '#test', 'round', 60);
    my $retired = $round->{timer}{on_expire};
    Mediabot::UserCommands::_quotegame_start_timer($bot, '#test', 'round', 60);
    my $replacement = refaddr($round->{timer});
    $retired->();
    is_deeply([$round->{active}, refaddr($round->{timer}), scalar @wire, timer_count($loop)],
        [1, $replacement, 0, 1], 'an old expiry cannot close a rearmed quote round with the same token');
    $loop->loop_once(0.01);
    is_deeply([$round->{active}, scalar @wire, timer_count($loop)], [0,1,0],
        'only the current quote timer closes the round and announces the answer');
}
{
    my ($bot, $round, $loop) = quotegame_fixture();
    my $error = bless {}, 'MB1119::QuoteSendError';
    local *Mediabot::Helpers::botPrivmsg = sub {die $error};
    Mediabot::UserCommands::_quotegame_start_timer($bot, '#test', 'round', 60);
    my $probe = $round->{timer}; weaken($probe);
    my $ok = eval {$loop->loop_once(0.01); 1};
    my $got = $@;
    is_deeply([!$ok && (refaddr($got) // 0) == refaddr($error) ? 1 : 0,
        $round->{active}, timer_count($loop), defined($probe) ? 1 : 0],
        [1,0,0,0], 'quote expiry frees its notifier even when sending throws');
}
{
    my ($bot, $round, $loop) = quotegame_fixture();
    my @wire;
    local *Mediabot::Helpers::botPrivmsg = sub {push @wire, $_[2]; 1};
    my $start = IO::Async::Timer::Countdown->can('start');
    my $ok;
    {
        local *IO::Async::Timer::Countdown::start = sub {
            $start->(@_);
            die "injected quote timer start failure\n";
        };
        $ok = eval {Mediabot::UserCommands::_quotegame_start_timer($bot, '#test', 'round', 60); 1};
    }
    is_deeply([$ok ? 1 : 0, $round->{active}, timer_count($loop), exists($round->{timer}) ? 1 : 0],
        [1,1,0,0], 'quote timer setup failure retains the round for lazy expiry and detaches the failed arm');
    Mediabot::UserCommands::checkQuotegameAnswer($bot, 'Player', '#test', 'late');
    is_deeply([$round->{active}, scalar @wire, timer_count($loop)], [0,1,0],
        'lazy quote expiry still works once after timer setup fails');
}
{
    my $loop=IO::Async::Loop->really_new;
    my $owner=bless {},'MB1212::NativePayload';my $weak=$owner;weaken($weak);
    my $calls=0;
    my $timer=countdown(loop=>$loop,delay=>60,on_expire=>(sub {my($held)=@_;return sub {$calls++ if $held}})->($owner));
    my $callback=$timer->{on_expire};undef $owner;
    is(cancel_countdown($timer),1,'native cancellation stops and removes its notifier');
    is(timer_count($loop),0,'native cancelled timer leaves the loop immediately');
    ok(!defined $weak,'native cancellation releases captured payload before expiry');
    $callback->();is($calls,0,'retained native callback stays inert');
    is(cancel_countdown($timer),1,'native cancellation is idempotent');
}

MB881OutputFixture::with_policy(sub {
    my $bot = MB881OutputFixture::new_bot(); $bot->{loop} = IO::Async::Loop->really_new;
    $bot->{policy}{AntiFlood} = 1; $bot->{blocked} = 1;
    privmsg($bot, '#test', 'retired'); action($bot, '#test', 'old action');
    my $q = $bot->{_flood_outq}{'#test'};
    is(timer_count($bot->{loop}), 1, 'native flood queue owns one countdown');
    Mediabot::setIrc($bot, $bot->{irc});
    is(timer_count($bot->{loop}), 1, 'same transport retains native flood countdown');
    my $fresh = bless {wire=>[]}, 'MB881::IRC';
    Mediabot::setIrc($bot, $fresh);
    is(timer_count($bot->{loop}), 0, 'replacement immediately removes native flood notifier');
    is_deeply([$q->{items},$q->{armed},$q->{timer}], [[],0,undef], 'native retirement releases pending messages and handle');
    privmsg($bot, '#test', 'fresh'); $bot->{blocked} = 0;
    $bot->{loop}->loop_once(0.01);
    is_deeply([map {$_->{text}} @{$fresh->{wire}}], ['fresh'], 'only successor flood output reaches new transport');
    is(timer_count($bot->{loop}), 0, 'successor completes without leaking a notifier');
});

done_testing;
