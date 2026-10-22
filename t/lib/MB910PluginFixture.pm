package MB910PluginFixture;
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();
use Time::HiRes ();
use IO::Async::Loop;
use IO::Async::Timer::Countdown;
use Mediabot::CommandRegistry;
use Mediabot::EventBus;
use Mediabot::Scheduler;
use Mediabot::PluginManager;

{
    package MB910::Log;
    sub log { 1 }
    package MB910::Bot;
    sub command_registry { $_[0]{registry} }
    sub events { $_[0]{events} }
    sub getLoop { $_[0]{loop} }
    package MB910::Command;
    sub nick { 'Alice' }
    sub channel { '#test' }
    sub args { [] }
    sub is_private { 0 }
    sub reply { $_[0]{replies}++;1 }
    sub reply_private { 1 }
    package MB910::Common;
    our $control;
    sub new {
        my ($class,%args)=@_;
        my $o=bless {context=>$args{context},control=>$control,resources=>[],starts=>0,stops=>0},$class;
        $control->{object}=$o;return $o;
    }
    sub probe { $_[0]{context}->reply($_[2],'active');1 }
    sub tick { $_[0]{control}{jobs}++;1 }
    sub stop {
        my ($s,%args)=@_;$s->{stops}++;push @{$s->{control}{trace}},'stop';
        $s->{stop_context_ok}=Scalar::Util::refaddr($args{context})==Scalar::Util::refaddr($s->{context});
        MB910PluginFixture::_free($s);
        die "MB910 cleanup failure\n" if $s->{control}{stop_fail};
        return 1;
    }
}
use Scalar::Util ();
my $root;
sub _root {
    return $root if $root;
    $root=tempdir('mb910-XXXXXX',TMPDIR=>1,CLEANUP=>1);
    for my $name ('activation-witness','nostart-witness') {
        make_path("$root/$name/lib");
        my $class=$name eq 'activation-witness'?'MB910::Witness':'MB910::NoStart';
        my $manifest={api=>3,name=>$name,version=>'1.0.0',description=>'Activation rollback witness',
            runtime=>{kind=>'perl',entrypoint=>'lib/Witness.pm',class=>$class},compatibility=>{},
            activation=>{default=>'off'},capabilities=>['irc.reply','scheduler.jobs'],
            commands=>{probe=>{source=>'public',help=>'Probe activation',level=>0,handler=>'probe'}},
            events=>[],jobs=>{tick=>{handler=>'tick',interval_seconds=>3600,first_delay_seconds=>0}},config_schema=>{}};
        open my $mf,'>',"$root/$name/plugin.json" or die $!;
        print $mf JSON::PP->new->canonical->encode($manifest);close $mf or die $!;
        open my $pf,'>',"$root/$name/lib/Witness.pm" or die $!;
        print $pf "package $class;\nuse strict;use warnings;\nour \@ISA=('MB910::Common');\n";
        print $pf <<'START' if $name eq 'activation-witness';
sub start {
    my ($s,%args)=@_;my $c=$s->{control};$s->{starts}++;push @{$c->{trace}},'start';
    die "MB910 start failure\n" if $c->{early_fail};
    my $listener=$c->{bus}->on('mb910_probe',sub {$c->{events}++});
    my $timer=IO::Async::Timer::Countdown->new(delay=>0.005,on_expire=>sub {$c->{ticks}++});
    push @{$s->{resources}},[$timer,$listener];$c->{loop}->add($timer);$timer->start;
    die "MB910 start failure\n" if $c->{start_fail};
    return $c->{false_return}?0:1;
}
START
        print $pf "1;\n";close $pf or die $!;
    }
    return $root;
}
sub _free {
    my ($o)=@_;my $c=$o->{control};
    for my $resource (@{delete($o->{resources})||[]}) {
        my ($timer,$listener)=@$resource;
        $timer->stop;$c->{loop}->remove($timer);$c->{bus}->off('mb910_probe',$listener);
    }
    $o->{resources}=[];
}
sub _context {
    my ($case)=@_;my $loop=IO::Async::Loop->new;my $bus=Mediabot::EventBus->new;
    my $bot=bless {registry=>Mediabot::CommandRegistry->new,events=>$bus,loop=>$loop,logger=>bless({},'MB910::Log')},'MB910::Bot';
    $bot->{scheduler}=Mediabot::Scheduler->new(loop=>$loop,logger=>$bot->{logger});
    my $m=Mediabot::PluginManager->new(bot=>$bot,plugin_dir=>_root());
    my $control={loop=>$loop,bus=>$bus,trace=>[],ticks=>0,events=>0,jobs=>0,
        start_fail=>$case =~ /\A(?:native_start_failure|retry_after_failure|load_enable_failure|cleanup_exception_primary)\z/?1:0,
        early_fail=>$case eq 'failure_before_resource'?1:0,stop_fail=>$case eq 'cleanup_exception_primary'?1:0,
        false_return=>$case eq 'false_return_nominal'?1:0};
    return ($m,$bot,$control);
}
sub _pump {
    my ($c)=@_;my $until=Time::HiRes::time()+0.025;
    while (Time::HiRes::time()<$until) {$c->{loop}->loop_once(0.005)}
}
sub _one {
    my ($case)=@_;my ($m,$bot,$c)=_context($case);
    my $name=$case eq 'no_start_hook_job_failure'?'nostart-witness':'activation-witness';
    local $MB910::Common::control=$c;
    my $entry;my $loaded=eval {
        $entry=$m->load_package_v3($name,grants=>['irc.reply','scheduler.jobs'],
            channel_policies=>{'#test'=>{mode=>'on',config=>{}}},enable=>$case eq 'load_enable_failure'?1:0);1;
    };my $load_error=$@;
    my $o=$c->{object};my $task="plugin.v3.$name.tick";
    my $native_start=Mediabot::Scheduler->can('start');
    no warnings 'redefine';
    local *Mediabot::Scheduler::start=sub {
        my ($s,$n)=@_;my $r=$native_start->(@_);
        return 0 if $case eq 'job_start_failure_nominal' || $case eq 'no_start_hook_job_failure';
        return $r;
    };
    my $enabled=$case eq 'load_enable_failure'?$loaded:eval {$m->enable($name);1};
    my $error=$case eq 'load_enable_failure'?$load_error:$@;
    my $ok;
    if ($case eq 'nominal_success' || $case eq 'false_return_nominal') {
        $c->{bus}->emit('mb910_probe');_pump($c);
        my $ctx=bless {replies=>0},'MB910::Command';
        $bot->{registry}->handler_for('probe','public')->($ctx);
        my $before=$c->{ticks};$m->disable($name);$m->disable($name);
        $c->{bus}->emit('mb910_probe');_pump($c);
        $ok=$enabled && $ctx->{replies}==1 && $before==1 && $c->{ticks}==1 && $c->{events}==1
            && $c->{jobs}==1 && $o->{starts}==1 && $o->{stops}==1 && $o->{stop_context_ok}
            && !$m->is_enabled($name) && !$c->{bus}->listener_count('mb910_probe');
    }
    elsif ($case eq 'no_start_hook_job_failure') {
        $ok=!$enabled && $error =~ /failed to start API v3 job 'tick'/ && $o->{stops}==0 && !$m->is_enabled($name);
    }
    else {
        my $expected=$case eq 'job_start_failure_nominal'?qr/failed to start API v3 job 'tick'/:qr/MB910 start failure/;
        my $task_stopped=!$bot->{scheduler}{_tasks}{$task} || !$bot->{scheduler}{_tasks}{$task}{started};
        $c->{bus}->emit('mb910_probe');_pump($c);
        $ok=!$enabled && $error =~ $expected && $error !~ /MB910 cleanup failure/ && !$m->is_enabled($name)
            && $o->{stops}==1 && $o->{stop_context_ok} && !$c->{bus}->listener_count('mb910_probe')
            && $c->{ticks}==0 && $c->{events}==0 && $task_stopped;
        if ($case eq 'load_enable_failure') {
            $ok &&= !$m->is_registered($name) && !$bot->{registry}->has_command('probe','public')
                && !exists($bot->{scheduler}{_tasks}{$task});
        }
        if ($case eq 'retry_after_failure') {
            $c->{start_fail}=0;$m->enable($name);$c->{bus}->emit('mb910_probe');_pump($c);
            my $one=$c->{ticks}==1 && $c->{events}==1 && $c->{jobs}==1
                && $o->{starts}==2 && $o->{stops}==1;
            $m->disable($name);
            $ok &&= $one && $o->{stops}==2 && !$c->{bus}->listener_count('mb910_probe');
        }
    }
    # Reference failures must not leak test timers/listeners into later cases.
    _free($o);$c->{stop_fail}=0;$m->unregister_plugin($name);delete $c->{object};
    return {case=>$case,ok=>$ok?1:0};
}
sub run_contracts {
    return [map {
        my $case=$_;my (@warnings,$result);
        {local $SIG{__WARN__}=sub {push @warnings,@_};$result=eval {_one($case)}}
        my $error=$@;$result||={case=>$case,ok=>0};$result->{ok}=0 if $error || @warnings;
        $result->{error}="$error" if $error;$result->{warnings}=\@warnings if @warnings;$result;
    } qw(native_start_failure retry_after_failure load_enable_failure cleanup_exception_primary
        failure_before_resource false_return_nominal job_start_failure_nominal no_start_hook_job_failure nominal_success)];
}
1;
