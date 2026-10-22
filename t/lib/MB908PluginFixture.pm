package MB908PluginFixture;
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();
use IO::Async::Loop;
use Time::HiRes ();
use Mediabot::CommandRegistry;
use Mediabot::EventBus;
use Mediabot::Scheduler;
use Mediabot::PluginManager;

{
    package MB908::Log;
    sub log { 1 }
    package MB908::Bot;
    sub command_registry { $_[0]{registry} }
    sub events { $_[0]{events} }
    sub getLoop { $_[0]{loop} }
    sub plugin_channel_message { push @{$_[0]{wire}}, [$_[1],$_[2]]; 1 }
    package MB908::Command;
    sub nick { 'Alice' }
    sub channel { '#test' }
    sub args { [] }
    sub is_private { 0 }
    sub reply { push @{$_[0]{wire}}, ['reply',$_[1]]; 1 }
    sub reply_private { push @{$_[0]{wire}}, ['notice',$_[1]]; 1 }
}
my $root;
my @caps=qw(irc.reply irc.notice irc.channel_message events.subscribe scheduler.jobs);
sub _root {
    return $root if $root;
    $root=tempdir('mb908-XXXXXX',TMPDIR=>1,CLEANUP=>1);
    make_path("$root/witness/lib");
    my $manifest={api=>3,name=>'witness',version=>'1.0.0',description=>'Lifecycle test witness',
        runtime=>{kind=>'perl',entrypoint=>'lib/Witness.pm',class=>'MB908::Witness'},
        compatibility=>{mediabot=>'>=3.6dev'},activation=>{default=>'off'},capabilities=>\@caps,
        commands=>{
            capture=>{source=>'public',help=>'Capture an invocation',level=>0,handler=>'command_capture'},
            fallback=>{source=>'public',help=>'Exercise legacy fallback',level=>0,handler=>'command_capture',migration=>'legacy-public-fallback'},
        },events=>[{name=>'scheduler.minute',version=>1,handler=>'event_minute'}],
        jobs=>{tick=>{handler=>'job_tick',interval_seconds=>3600,first_delay_seconds=>0}},config_schema=>{}};
    open my $json,'>',"$root/witness/plugin.json" or die $!;
    print $json JSON::PP->new->canonical->encode($manifest);close $json or die $!;
    open my $perl,'>',"$root/witness/lib/Witness.pm" or die $!;
    print $perl <<'PLUGIN';
package MB908::Witness;
use strict; use warnings;
sub new { my ($class,%args)=@_;bless {context=>$args{context},commands=>[],jobs=>[],events=>0},$class }
sub start { 1 }
sub stop { 1 }
sub command_capture {
    my ($self,$context,$inv)=@_;push @{$self->{commands}},$inv;
    $context->reply($inv,'reply');$context->notice($inv,'notice');1;
}
sub job_tick {
    my ($self,$context,$inv)=@_;push @{$self->{jobs}},$inv;
    my $hook=delete $self->{hook};$hook->() if $hook;
    $context->channel_message($inv,'job');1;
}
sub event_minute { $_[0]{events}++;1 }
1;
PLUGIN
    close $perl or die $!;
    return $root;
}
sub _context {
    my $loop=IO::Async::Loop->new;
    my $bot=bless {registry=>Mediabot::CommandRegistry->new,events=>Mediabot::EventBus->new,
        loop=>$loop,wire=>[],logger=>bless({},'MB908::Log')},'MB908::Bot';
    $bot->{scheduler}=Mediabot::Scheduler->new(loop=>$loop,logger=>$bot->{logger});
    $bot->{registry}->register_command(name=>'fallback',source=>'public',level=>0,
        metadata=>{builtin=>1,dispatch=>'registry',migration_fallback=>1},
        handler=>sub {push @{$bot->{wire}},['fallback'];1});
    my $manager=Mediabot::PluginManager->new(bot=>$bot,plugin_dir=>_root());
    my $entry=_load($manager);
    my $ctx=bless {wire=>$bot->{wire}},'MB908::Command';
    return ($manager,$entry,$bot,$ctx);
}
sub _load {
    my ($manager,$grants)=@_;
    return $manager->load_package_v3('witness',grants=>$grants||\@caps,enable=>1,
        channel_policies=>{'#test'=>{mode=>'on',config=>{}},'#test2'=>{mode=>'on',config=>{}}});
}
sub _event { return {minute=>1,hour=>2,dow=>3,mday=>4,month=>5,year=>2026} }
sub _one {
    my ($case)=@_;
    my ($m,$old,$bot,$ctx)=_context();my $s=$bot->{scheduler};
    my $task='plugin.v3.witness.tick';
    my $handler=$bot->{registry}->handler_for('capture','public');
    my $fallback=$bot->{registry}->handler_for('fallback','public');
    my $job_cb=$s->{_tasks}{$task}{cb};
    my $listener=$old->{event_listeners}[0][1]{cb};
    $handler->($ctx);$job_cb->();
    my $inv=$old->{object}{commands}[0];my $job=$old->{object}{jobs}[0];
    my $authority=$old->{metadata}{plugin_context};my $ok=0;
    if ($case eq 'native_current') {
        $bot->{events}->emit('plugin_cron_observed',_event());
        my $end=Time::HiRes::time()+1;
        while (($old->{object}{events}<2 || @{$old->{object}{jobs}}<4) && Time::HiRes::time()<$end) {
            $bot->{loop}->loop_once(0.01);
        }
        $ok=$old->{object}{events}==2 && @{$old->{object}{jobs}}==4
            && @{$ctx->{wire}}==6 && $inv->output_allowed && $job->output_allowed;
    }
    elsif ($case eq 'current_policy_and_quarantine') {
        $m->set_v3_channel_policy('witness','#test',mode=>'off');
        my $off=!$inv->output_allowed && !$job->output_allowed;
        $m->set_v3_channel_policy('witness','#test',mode=>'on');
        $m->set_v3_quarantine('witness','command','capture','#test');
        $m->set_v3_quarantine('witness','job','tick','#test');
        my $held=!$inv->output_allowed && !$job->output_allowed;
        $m->reset_v3_quarantine('witness','command','capture','#test');
        $m->reset_v3_quarantine('witness','job','tick','#test');
        $ok=$off && $held && $inv->output_allowed && $job->output_allowed;
    }
    elsif ($case eq 'current_fallback') {
        $m->set_v3_channel_policy('witness','#test',mode=>'observe');
        my $n=@{$ctx->{wire}};$fallback->($ctx);
        my $observed=@{$ctx->{wire}}==$n+1 && $ctx->{wire}[-1][0] eq 'fallback';
        $m->disable('witness');$fallback->($ctx);
        $ok=$observed && @{$ctx->{wire}}==$n+2 && $ctx->{wire}[-1][0] eq 'fallback';
    }
    elsif ($case eq 'job_disable_mid_fanout' || $case eq 'job_reload_mid_fanout') {
        $old->{object}{jobs}=[];
        $old->{object}{hook}=sub {
            if ($case eq 'job_disable_mid_fanout') {$m->disable('witness')}
            else {$m->unregister_plugin('witness');_load($m)}
        };
        my $n=@{$ctx->{wire}};$job_cb->();
        $ok=@{$old->{object}{jobs}}==1 && @{$ctx->{wire}}==$n;
    }
    else {
        $m->unregister_plugin('witness');
        my @grants=$case eq 'reduced_grants'?grep {$_ ne 'irc.reply'} @caps:@caps;
        my $new=_load($m,\@grants);my $n=@{$ctx->{wire}};
        if ($case eq 'retained_command_reply' || $case eq 'reduced_grants') {
            $ok=!$authority->reply($inv,'old reply') && !$inv->output_allowed && @{$ctx->{wire}}==$n;
        }
        elsif ($case eq 'retained_command_notice') {
            $ok=!$authority->notice($inv,'old notice') && @{$ctx->{wire}}==$n;
        }
        elsif ($case eq 'retained_job_output') {
            $ok=!$authority->channel_message($job,'old job') && !$job->output_allowed && @{$ctx->{wire}}==$n;
        }
        elsif ($case eq 'retained_command_handler' || $case eq 'retained_fallback_handler') {
            my $calls=@{$old->{object}{commands}};
            ($case eq 'retained_command_handler'?$handler:$fallback)->($ctx);
            $ok=@{$old->{object}{commands}}==$calls && @{$ctx->{wire}}==$n;
        }
        elsif ($case eq 'retained_job_callback') {
            my $calls=@{$old->{object}{jobs}};$job_cb->();
            $ok=@{$old->{object}{jobs}}==$calls && @{$ctx->{wire}}==$n;
        }
        elsif ($case eq 'retained_event_listener') {
            my $pending=$old->{event_queue}->pending_count;$listener->(_event());
            $ok=$old->{event_queue}->pending_count==$pending;
        }
        elsif ($case eq 'retained_event_dispatch') {
            require Mediabot::Plugin::EventCatalogV3;
            my $env=Mediabot::Plugin::EventCatalogV3->envelope('scheduler.minute',1,_event());
            my $calls=$old->{object}{events};
            $old->{event_queue}{dispatch}->({envelope=>$env,method=>'event_minute',channel=>'#test'});
            $ok=$old->{object}{events}==$calls;
        }
        else {die "unknown fixture case: $case"}
        # The replacement remains operational after stale work is rejected.
        if ($case ne 'reduced_grants') {
            my $before=@{$new->{object}{commands}};
            $bot->{registry}->handler_for('capture','public')->($ctx);
            $ok &&= @{$new->{object}{commands}}==$before+1;
        }
    }
    $m->unregister_plugin('witness');
    return {case=>$case,ok=>$ok?1:0};
}
sub run_contracts {
    return [map {
        my $case=$_;my (@warnings,$result);
        {local $SIG{__WARN__}=sub {push @warnings,@_};$result=eval {_one($case)}}
        my $error=$@;
        $result||={case=>$case,ok=>0};
        $result->{ok}=0 if $error || @warnings;
        $result->{error}="$error" if $error;
        $result->{warnings}=\@warnings if @warnings;
        $result;
    } qw(native_current current_policy_and_quarantine current_fallback
        retained_command_reply retained_command_notice retained_job_output reduced_grants
        retained_command_handler retained_fallback_handler retained_job_callback
        retained_event_listener retained_event_dispatch job_disable_mid_fanout job_reload_mid_fanout)];
}
1;
