use strict;
use warnings;
use Test::More;
use JSON::PP;
use Mediabot::Spark::Replay qw(replay_events);
{
    package MB949::Conf;
    sub get {$_[0]{$_[1]}}
}
my $run=sub {
    my ($conf,$events)=@_;
    return replay_events(conf=>bless({%$conf},'MB949::Conf'),channel=>'#test',bot_nick=>'Mediabot',events=>$events);
};
my @chat=map {+{at=>$_,type=>'line',nick=>$_%2?'Bob':'Alice',message=>'a normal sentence'}} 0..3;
my @solo=({at=>0,type=>'line',nick=>'Alice',message=>'a normal sentence'},{at=>121,type=>'probe'});
my $default=$run->({},\@solo);
my $short=$run->({'main.SPARK_MIN_SILENCE_SECONDS'=>60},\@solo);
is($default->{probes}[0]{revival},'skip','default silence still refuses an early solo revival');
is($short->{probes}[0]{revival},'dryrun_candidate','configured short silence now affects the replay like the live runtime');
my $normal=$run->({},[@chat,{at=>50,type=>'probe'}]);
is($normal->{probes}[0]{momentum},'action_candidate','ordinary small-room momentum retains its calibrated default');
my $slower=$run->({'main.SPARK_ACTION_MIN_PAUSE_SECONDS'=>300},[@chat,{at=>50,type=>'probe'}]);
is($slower->{probes}[0]{momentum_reason},'momentum_busy','configured breathing pause prevents a false early candidate');

# Execute the real live factory, without executing the program's startup.
open my $main,'<','mediabot.pl' or die $!;my $source=do {local $/;<$main>};close $main;
my ($factory)=$source =~ /(sub _spark_runtime \{.*?\n\})(?=\n+sub )/s;
die 'native Spark factory missing' unless $factory;
eval "package MB949::Live; $factory; 1" or die $@;
my @settings=(
 ['min_silence_seconds','SPARK_MIN_SILENCE_SECONDS',3600],
 ['candidate_probe_seconds','SPARK_CANDIDATE_PROBE_SECONDS',600],
 ['action_activity_window_seconds','SPARK_ACTION_ACTIVITY_WINDOW_SECONDS',900],
 ['action_min_humans','SPARK_ACTION_MIN_HUMANS',7],
 ['action_min_lines','SPARK_ACTION_MIN_LINES',22],
 ['action_min_pause_seconds','SPARK_ACTION_MIN_PAUSE_SECONDS',90],
 ['action_max_pause_seconds','SPARK_ACTION_MAX_PAUSE_SECONDS',360],
 ['action_probe_seconds','SPARK_ACTION_PROBE_SECONDS',45],
 ['action_cooldown_seconds','SPARK_ACTION_COOLDOWN_SECONDS',2400],
);
my %conf=map {'main.'.$_->[1]=>$_->[2]} @settings;
my $live=MB949::Live::_spark_runtime({conf=>bless({%conf},'MB949::Conf')});
my $replay;
{
 no warnings 'redefine';
 my $native=\&Mediabot::Spark::Orchestrator::new;
 local *Mediabot::Spark::Orchestrator::new=sub {$replay=$native->(@_);return $replay};
 $run->(\%conf,[{at=>0,type=>'probe'}]);
}
for my $setting (@settings) {
 is($live->{$setting->[0]},$setting->[2],"live factory retains configured $setting->[0]");
 is($replay->{$setting->[0]},$live->{$setting->[0]},"replay shares live $setting->[0]");
}
my %invalid=map {'main.'.$_->[1]=>'invalid'} @settings;
my $invalid=$run->(\%invalid,[@chat,{at=>50,type=>'probe'}]);
is_deeply($invalid,$normal,'invalid cadence values use the same native defaults');
my %range=map {'main.'.$_->[1]=>999999999} @settings;
is_deeply($run->(\%range,[@chat,{at=>50,type=>'probe'}]),$normal,'out-of-range values preserve native fallback rather than arbitrary clamping');

my $accepted=eval {$run->({},[@chat,{at=>40,type=>'output',accepted=>1},{at=>50,type=>'probe'}])};
ok($accepted,'metadata-only accepted output is supported');
is($accepted ? $accepted->{probes}[0]{momentum_reason} : '', 'bot_pressure','accepted bot output delays momentum without a self echo');
is($accepted ? $accepted->{probes}[0]{revival_reason} : '', 'bot_pressure','accepted bot output also delays the revival lane');
my $refused=eval {$run->({},[@chat,{at=>40,type=>'output',accepted=>0},{at=>50,type=>'probe'}])};
is_deeply($refused,$normal,'a refused or merely queued output creates no accepted-output pressure');
my $unobserved=eval {$run->({},[{at=>0,type=>'output',accepted=>1},{at=>50,type=>'probe'}])};
is_deeply($unobserved,$run->({},[{at=>50,type=>'probe'}]),'output alone creates no room audience or human activity');
for my $output (
 {at=>40,type=>'output'}, {at=>40,type=>'output',accepted=>2},
 {at=>40,type=>'output',accepted=>[]}, {at=>40,type=>'output',accepted=>"1\n"},
 {at=>40,type=>'output',accepted=>1,message=>'private text'},
 {at=>40,type=>'output',accepted=>1,nick=>'private identity'},
) {
 ok(!eval {$run->({},[@chat,$output,{at=>50,type=>'probe'}]);1},'invalid or content-bearing output metadata is refused');
}
if ($accepted) {
 my $json=JSON::PP->new->encode($accepted);
 unlike($json,qr/Alice|Bob|normal sentence|accepted/,'reports retain only decision metadata and counters');
 is_deeply([sort keys %$accepted],[sort qw(probes excluded decisions repeated_momentum)],'the public report shape remains compatible');
} else {fail('private content is not returned');fail('report shape stays compatible')}

my $busy=$run->({},[(map {+{at=>$_,type=>'line',nick=>'Speaker'.($_%6),message=>'ordinary chat'}} 0..11),{at=>41,type=>'probe'}]);
is($busy->{probes}[0]{momentum_regime},'crowded','crowded-room rhythm remains audience-adaptive');
my $prefix=$run->({'main.MAIN_PROG_CMD_CHAR'=>'.'},[@chat,
 {at=>40,type=>'line',nick=>'Alice',message=>'.q view 42'},{at=>50,type=>'probe'}]);
is($prefix->{probes}[0]{momentum},'skip','real command prefix still creates command pressure instead of another human turn');
done_testing;
