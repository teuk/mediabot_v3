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

# MB1213: exercise the actual paced owner without loading Helpers/IRC runtime.
{
    require Mediabot::IRC::PacedOutput;
    require MB882TimerFixture;
    no warnings qw(redefine once);
    local *IO::Async::Timer::Countdown::new = sub {shift; MB882::Timer->new(@_)};
    my @wire;
    local *Mediabot::IRC::Output::privmsg = sub {push @wire, $_[2]};
    my $queue = sub {Mediabot::IRC::PacedOutput::_queue_irc_chunks(@_)};
    my $retire = sub {
        my ($bot) = @_;
        my $old = delete $bot->{_external_ai_output_queues};
        Mediabot::IRC::PacedOutput::retire_privmsg_queues($bot, $old);
    };
    for my $mode ('normal', 'stop', 'remove') {
        @wire = ();
        my $bot = bless {loop=>MB882::Loop->new, logger=>bless({rows=>[]}, 'MB882::Logger')}, 'MB882::Bot';
        my $payload = bless {}, 'MB1213Payload';
        my $weak = $payload; Scalar::Util::weaken($weak);
        {
            my $held = $payload;
            $queue->($bot, '#test', [qw(first old)], 10000, 'fixture', {can_send=>sub {defined $held}});
        }
        undef $payload;
        $queue->($bot, '#test', ['tail'], 0);
        $queue->($bot, '#other', [qw(other1 other2)], 10000);
        my $old = $bot->{_external_ai_output_queues};
        my @states = values %$old;
        my @callbacks = @{$bot->{loop}{callbacks}};
        my $stop = MB882::Timer->can('stop'); my $remove = MB882::Loop->can('remove');
        {
            local *MB882::Timer::stop = sub {die "stop failure\n" if $mode eq 'stop'; $stop->(@_)};
            local *MB882::Loop::remove = sub {die "remove failure\n" if $mode eq 'remove'; $remove->(@_)};
            is($retire->($bot), $mode eq 'normal' ? 1 : 0, 'paced retirement reports cleanup result');
        }
        ok(!defined $weak, 'retirement releases guarded payload immediately despite retained callbacks/state');
        is_deeply($old, {}, 'all old targets detached');
        ok(!grep({$_->{current} || @{$_->{batches}} || $_->{retire} || $_->{timer}} @states), 'old state no longer owns batches, pump or notifier');
        $_->() for @callbacks;
        is_deeply(\@wire, [qw(first other1)], 'retained callbacks cannot send retired chunks');
        is(scalar keys %{$bot->{loop}{attached}}, $mode eq 'remove' ? 2 : 0, 'every removal attempted despite stop failure');
        is(scalar @{$bot->{logger}{rows}}, $mode eq 'normal' ? 0 : 1, 'incomplete cleanup diagnosed once');
        is(Mediabot::IRC::PacedOutput::retire_privmsg_queues($bot, $old), 1, 'repeat retirement is inert');
    }
    {
        @wire = (); my $bot = bless {loop=>MB882::Loop->new}, 'MB882::Bot';
        $queue->($bot, '#test', [qw(first old)], 10000);
        my $stop = MB882::Timer->can('stop'); my $once = 0;
        {
            local *MB882::Timer::stop = sub {
                unless ($once++) {$queue->($bot, '#test', [qw(new1 new2)], 10000)}
                $stop->(@_);
            };
            $retire->($bot);
        }
        is(scalar keys %{$bot->{loop}{attached}}, 1, 'cleanup reentry retains successor notifier');
        $bot->{loop}->drain;
        is_deeply(\@wire, [qw(first new1 new2)], 'successor queue survives old retirement');
    }
    {
        @wire = (); my $bot = bless {loop=>MB882::Loop->new}, 'MB882::Bot';
        my $add = MB882::Loop->can('add');
        {
            local *MB882::Loop::add = sub {$add->(@_); $retire->($bot)};
            $queue->($bot, '#test', [qw(first old)], 10000);
        }
        is(scalar keys %{$bot->{loop}{attached}}, 0, 'late setup result is retired');
        $_->() for @{$bot->{loop}{callbacks}};
        is_deeply(\@wire, ['first'], 'late setup cannot replay old output');
    }
    {
        @wire = (); my $bot = bless {loop=>MB882::Loop->new}, 'MB882::Bot';
        my $add = MB882::Loop->can('add'); my $once = 0;
        {
            local *MB882::Loop::add = sub {$add->(@_); $_[1]{on_expire}->() unless $once++};
            $queue->($bot, '#test', [qw(first inline pending)], 10000);
        }
        my $state = $bot->{_external_ai_output_queues}{'#test'};
        ok($state->{timer}, 'inline expiry retains successor timer handle');
        $retire->($bot);
        is(scalar keys %{$bot->{loop}{attached}}, 0, 'successor after inline expiry remains cancellable');
        $_->() for @{$bot->{loop}{callbacks}};
        is_deeply(\@wire, [qw(first inline)], 'inline successor stays silent after retirement');
    }

    {
        @wire = (); my $bot = bless {loop=>MB882::Loop->new}, 'MB882::Bot';
        my $add = MB882::Loop->can('add'); my $once = 0;
        {
            local *MB882::Loop::add = sub {
                $add->(@_);
                unless ($once++) {$_[1]{on_expire}->(); die "late add failure\n"}
            };
            eval {$queue->($bot, '#test', [qw(first inline successor)], 10000)};
            like($@, qr/late add failure/, 'post-inline setup exception remains visible');
        }
        ok($bot->{_external_ai_output_queues}{'#test'}{timer}, 'old setup failure cannot clear successor handle');
        $bot->{loop}->drain;
        is_deeply(\@wire, [qw(first inline successor)], 'new arm remains active after old setup exception');
    }
    {
        @wire = (); my $bot = bless {loop=>MB882::Loop->new}, 'MB882::Bot';
        {
            local *MB882::Timer::start = sub {die "failed arm\n"};
            eval {$queue->($bot, '#test', [qw(first pending)], 10000)};
            like($@, qr/failed arm/, 'failed arm still propagates');
        }
        my $state = $bot->{_external_ai_output_queues}{'#test'};
        is_deeply($state->{current}{chunks}, ['pending'], 'ordinary failure keeps recovery payload');
        $retire->($bot);
        ok(!$state->{current} && !@{$state->{batches}}, 'connection retirement also clears dormant recovery payload');
    }
}


# MB1214: real deferred owner and countdown, with deterministic loop failures.
{
    require Mediabot::IRC::DeferredOutput;
    require MB882TimerFixture;
    no warnings qw(redefine once);
    local *IO::Async::Timer::Countdown::new = sub {shift; MB882::Timer->new(@_)};
    local *Mediabot::Helpers::_arm_flood_drain = sub {goto &Mediabot::IRC::DeferredOutput::_arm_flood_drain};
    local *Mediabot::Helpers::_drain_flood_queue = sub {goto &Mediabot::IRC::DeferredOutput::_drain_flood_queue};
    my @wire;
    local *Mediabot::IRC::DeferredOutput::botPrivmsg = sub {push @wire, $_[2]};
    my $enqueue = sub {
        my ($bot, $target, @messages) = @_;
        my $q = $bot->{_flood_outq}{$target} ||= {items=>[], armed=>0};
        push @{$q->{items}}, map {['privmsg', $_, undef, {expires_at=>1e20}]} @messages;
        Mediabot::IRC::DeferredOutput::_arm_flood_drain($bot, $target);
        return $q;
    };
    my $retire = sub {
        my ($bot) = @_;
        Mediabot::IRC::DeferredOutput::retire_flood_queues($bot, delete $bot->{_flood_outq});
    };
    for my $mode (qw(normal stop remove)) {
        @wire=();my $bot=bless {loop=>MB882::Loop->new,logger=>bless({rows=>[]},'MB882::Logger')},'MB882::Bot';
        my $q=$enqueue->($bot,'#test','old','tail');
        $enqueue->($bot,'#other','other');
        my $old=$bot->{_flood_outq};my @callbacks=@{$bot->{loop}{callbacks}};
        my $payload=bless {},'MB1214Payload';my $weak=$payload;weaken($weak);
        $q->{items}[0][3]{probe}=$payload;undef $payload;
        my $stop=MB882::Timer->can('stop');my $remove=MB882::Loop->can('remove');
        {
            local *MB882::Timer::stop=sub {die "stop failed\n" if $mode eq 'stop';$stop->(@_)};
            local *MB882::Loop::remove=sub {die "remove failed\n" if $mode eq 'remove';$remove->(@_)};
            is($retire->($bot),$mode eq 'normal'?1:0,'flood retirement reports cleanup outcome');
        }
        ok(!defined $weak,'retained queue and callbacks release response payload immediately');
        is_deeply([$old,$q->{items},$q->{armed},$q->{timer},$q->{arm}],[{},[],0,undef,undef],'all old queue ownership revoked');
        $_->() for @callbacks;
        is_deeply(\@wire,[],'old callbacks cannot send');
        is(scalar keys %{$bot->{loop}{attached}},$mode eq 'remove'?2:0,'independent removal attempted for every old target');
        is(scalar @{$bot->{logger}{rows}},$mode eq 'normal'?0:1,'cleanup failure reported once');
        is(Mediabot::IRC::DeferredOutput::retire_flood_queues($bot,$old),1,'repeat retirement is inert');
    }
    {
        @wire=();my $bot=bless {loop=>MB882::Loop->new},'MB882::Bot';
        $enqueue->($bot,'#test','old');my $stop=MB882::Timer->can('stop');my $once=0;
        {local *MB882::Timer::stop=sub {unless($once++){$enqueue->($bot,'#test','new','tail')}$stop->(@_)};
         $retire->($bot);}
        is(scalar keys %{$bot->{loop}{attached}},1,'new drain survives reentrant cleanup');
        $bot->{loop}->drain;
        is_deeply(\@wire,[qw(new tail)],'successor keeps FIFO delivery');
    }
    {
        @wire=();my $bot=bless {loop=>MB882::Loop->new},'MB882::Bot';my $add=MB882::Loop->can('add');
        {local *MB882::Loop::add=sub {$add->(@_);$retire->($bot)};
         $enqueue->($bot,'#test','old');}
        is(scalar keys %{$bot->{loop}{attached}},0,'late setup result cancelled');
        $_->() for @{$bot->{loop}{callbacks}};
        is_deeply(\@wire,[],'late timer stays inert');
    }
    for my $fail (0,1) {
        @wire=();my $bot=bless {loop=>MB882::Loop->new},'MB882::Bot';my $add=MB882::Loop->can('add');my $once=0;
        {local *MB882::Loop::add=sub {$add->(@_);unless($once++){$_[1]{on_expire}->();die "late add error\n" if $fail}};
         my $ok=eval {$enqueue->($bot,'#test','inline','pending');1};
         is($ok?1:0,$fail?0:1,'inline setup retains original exception policy');}
        ok($bot->{_flood_outq}{'#test'}{timer},'inline expiry preserves successor handle');
        $retire->($bot);
        is(scalar keys %{$bot->{loop}{attached}},0,'successor can be cancelled after inline setup');
        $_->() for @{$bot->{loop}{callbacks}};
        is_deeply(\@wire,['inline'],'inline tail revoked without replay');
    }
    {
        my $bot=bless {loop=>MB882::Loop->new},'MB882::Bot';
        {local *MB882::Timer::start=sub {die "arm failed\n"};
         eval {$enqueue->($bot,'#test','pending')};like($@,qr/arm failed/,'setup failure propagates');}
        my $q=$bot->{_flood_outq}{'#test'};
        is_deeply([$q->{armed},scalar @{$q->{items}}],[0,1],'ordinary failure retains rearmable payload');
        $retire->($bot);is_deeply($q->{items},[],'retirement clears dormant failed-arm queue');
    }
    {
        @wire=();my $bot=bless {loop=>MB882::Loop->new},'MB882::Bot';
        $enqueue->($bot,'#test','first','second');
        my $old_callback=$bot->{loop}{callbacks}[0];
        Mediabot::IRC::DeferredOutput::_drain_flood_queue($bot,'#test');
        is(scalar keys %{$bot->{loop}{attached}},1,'explicit drain replaces the pending arm without duplication');
        $old_callback->();
        is_deeply(\@wire,['first'],'cancelled pending arm cannot advance explicit drain');
        $bot->{loop}->drain;
        is_deeply(\@wire,[qw(first second)],'explicit drain preserves FIFO and single delivery');
        my $dormant={items=>[['action','unscheduled']],armed=>0};
        $bot->{_flood_outq}{'#idle'}=$dormant;
        $retire->($bot);
        is_deeply($dormant->{items},[],'unscheduled queue also releases payload');
    }

}

done_testing;
