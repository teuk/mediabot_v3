package MB940DiagnosticFixture;
use strict;
use warnings;
use utf8;
use MB938ChannelDiagnosticFixture ();
use MB939ActivityDiagnosticFixture ();
use MB908PluginFixture ();
use Mediabot::Diagnostics::Publisher;
use Mediabot::Plugin::ConfigSchemaV3;
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
use JSON::PP;
{
    package MB940::Conf;
    sub get {return $_[0]{$_[1]}}
}
my $json=JSON::PP->new->utf8->canonical;
sub check ($$) {die "$_[1]\n" unless $_[0]}
sub manager {
    my($bot)=@_;my($m,$entry)=MB908PluginFixture::_context();$bot->{plugin_manager}=$m;return($m,$entry);
}
sub collect {MB938ChannelDiagnosticFixture::collect($_[0])}
sub run_checks {
    my@out;my$group=sub{my($name,$cb)=@_;my$ok=eval{$cb->();1};push@out,{name=>$name,ok=>$ok?1:0,detail=>$ok?'':"$@"}};
    $group->('loaded plugin policy and capability observations never create ledgers or activate code',sub {
        my($b)=MB938ChannelDiagnosticFixture::setup();my($m,$entry)=manager($b);
        my$before=$json->encode([$m->{v3_failure_ledgers},$m->{v3_quarantines}]);my$runtime=$m->{v3_runtime};
        my$r=collect($b);my$p=$r->{plugins}{packages}[0];
        my$policy=$entry->{metadata}{channel_policy}->observation_for('#TEST');
        check($policy->{configured} && $policy->{mode} eq 'on' && !exists($policy->{config}),'policy observer copied configuration');
        check($p->{name} eq 'witness' && $p->{policy} eq 'on' && $p->{decision} eq 'active','native channel explanation');
        check($json->encode([$m->{v3_failure_ledgers},$m->{v3_quarantines}]) eq $before && $m->{v3_runtime}==$runtime,'observation allocated state');
        check(!@{$entry->{object}{commands}} && !$entry->{object}{events} && !@{$entry->{object}{jobs}},'plugin code invoked');
        $m->set_v3_channel_policy('witness','#test',mode=>'observe',config=>{});
        check(collect($b)->{plugins}{packages}[0]{decision} eq 'shadow','observe confused with output');
        $entry->{enabled}=0;check(collect($b)->{plugins}{packages}[0]{reason} eq 'plugin_disabled','disabled plugin hidden');
        $entry->{enabled}=1;$entry->{metadata}{effective_capabilities}=[];
        check(collect($b)->{plugins}{packages}[0]{missing_capabilities}>0,'missing grants hidden');
        $m->register_plugin(name=>'legacy',metadata=>{api=>1},enabled=>1);
        check(collect($b)->{plugins}{legacy_loaded}==1,'legacy policy invented');
    });
    $group->('retained plugin failures and quarantines are channel scoped detached and reset on reload',sub {
        my($b)=MB938ChannelDiagnosticFixture::setup();my($m,$entry)=manager($b);
        my$now=time;for my$i(1..5){$m->_record_v3_failure('witness',kind=>'command',resource=>'capture',channel=>'#TeST',occurred_at=>$now-$i,error=>'PRIVATE_KEY_MARKER https://private/secret')}
        $m->_record_v3_failure('witness',kind=>'event',resource=>'minute',channel=>'#private',occurred_at=>$now,error=>'PRIVATE_OTHER_MARKER');
        $m->_record_v3_failure('witness',kind=>'job',resource=>'tick',channel=>'',occurred_at=>$now,error=>'PRIVATE_INSTANCE_MARKER');
        $m->set_v3_quarantine('witness','command','capture','#test');
        $m->set_v3_quarantine('witness','command','capture','#test2');
        my$r=collect($b);my$p=$r->{plugins}{packages}[0];
        check($p->{retained_failures}==5 && @{$p->{recent}}==3 && $p->{last_failure_at}==$now-1 && $p->{quarantined_resources}==1,'scope order or bounds');
        check($json->encode($r)!~/PRIVATE_|private|fingerprint|https:/,'private error or unrelated channel leaked');
        $p->{recent}[0]{occurred_at}=0;check(collect($b)->{plugins}{packages}[0]{last_failure_at}==$now-1,'report aliases ledger');
        my$before=$json->encode($m->v3_failure_report('witness'));collect($b);
        check($json->encode($m->v3_failure_report('witness')) eq $before,'observation altered retention');
        $m->set_v3_channel_policy('witness','#Room[One]',mode=>'on',config=>{});
        $m->_record_v3_failure('witness',kind=>'command',resource=>'capture',channel=>'#Room[One]',error=>'PRIVATE_CASE_MARKER');
        my$folded=$m->channel_diagnostic_snapshot('#room{one}')->{packages}[0];
        check($folded->{configured} && $folded->{retained_failures}==0,'punctuation alias leaked foreign history');
        check($m->channel_diagnostic_snapshot('#room[one]')->{packages}[0]{retained_failures}==1,'canonical name case scope mismatch');
        for(1..20){$m->_record_v3_failure('witness',kind=>'event',resource=>'minute',channel=>'#private',error=>'PRIVATE_MARKER')}
        check(collect($b)->{plugins}{packages}[0]{retained_failures}==0,'evicted history fabricated');
        $m->unregister_plugin('witness');MB908PluginFixture::_load($m);
        check(collect($b)->{plugins}{packages}[0]{retained_failures}==0,'same-name replacement inherited failures');
    });
    $group->('RSS retained database error summary stays scoped and independent under real DBI faults',sub {
        my($b,$db,$probe)=MB938ChannelDiagnosticFixture::setup();
        $db->do(q{INSERT INTO RSS_FEED VALUES(1,7,'2026-10-24 03:04:05','PRIVATE_URL_MARKER'),(2,8,'2026-10-25 10:00:00','OTHER_MARKER')});
        my$r=collect($b);check($r->{rss_failures}{retained_feeds}==1 && $r->{rss_failures}{latest_db_time} eq '2026-10-24 03:04:05','RSS scope or timestamp');
        check($json->encode($r)!~/PRIVATE_|OTHER_|2026-10-25/,'raw RSS error leaked');
        for my$raise(0,1){for my$fault(qw(rss.prepare rss.execute rss.fetch)){
            ($b,$db,$probe)=MB938ChannelDiagnosticFixture::setup(raise=>$raise,fault=>$fault);$r=collect($b);
            check($r->{rss_failures}{state} eq 'unavailable' && $r->{database} eq 'fresh' && $r->{channel_joined} eq 'yes',"RSS fault poisoned other observations: $raise $fault");
        }}
    });
    $group->('scheduler exceptions are observed without messages and belong to the completing registration',sub {
        my($b)=MB938ChannelDiagnosticFixture::setup();MB939ActivityDiagnosticFixture::populate($b);
        my$s=$b->{scheduler};my$calls=0;
        $s->add(name=>'rss_poll_dispatch',interval=>30,autostart=>1,cb=>sub{++$calls;die 'PRIVATE_ERROR_MARKER'});
        $s->{_tasks}{rss_poll_dispatch}{timer}->invoke_event('on_tick');
        my$r=collect($b);my$t=$r->{activity}{tasks}{rss_poll_dispatch};
        check($calls==1 && $t->{callback_exceptions}==1 && $t->{last_exception_at}>0,'callback exception not observed');
        check($json->encode($r)!~/PRIVATE_ERROR/,'scheduler exception leaked');
        collect($b);check($calls==1,'diagnostic ran callback');
        $s->add(name=>'replace',interval=>30,autostart=>1,cb=>sub{
            $s->remove('replace');$s->add(name=>'replace',interval=>30,cb=>sub{1});die 'old callback failure';
        });
        $s->{_tasks}{replace}{timer}->invoke_event('on_tick');check(!$s->task_info('replace')->{callback_exceptions},'successor charged old exception');
        $s->add(name=>'restart',interval=>30,autostart=>1,cb=>sub{$s->restart('restart');die 'old generation failure'});
        $s->{_tasks}{restart}{timer}->invoke_event('on_tick');check(!$s->task_info('restart')->{callback_exceptions},'new generation charged old exception');
    });
    $group->('optional publisher writes only authorized fresh identities atomically; native Node reads the same report',sub {
        my($b,$db,$probe)=MB938ChannelDiagnosticFixture::setup();MB939ActivityDiagnosticFixture::populate($b);manager($b);
        my$dir=tempdir(CLEANUP=>1);my$s=$b->{scheduler};
        check(!Mediabot::Diagnostics::Publisher->install($b,$s) && !$s->task_info('channel_diagnostics_publish'),'publication enabled by default');
        $b->{conf}=bless{'main.CHANNEL_DIAGNOSTICS_DIR'=>$dir,'main.CHANNEL_DIAGNOSTICS_CHANNELS'=>'#test'},'MB940::Conf';
        my$publisher=Mediabot::Diagnostics::Publisher->install($b,$s);
        check($publisher && $s->task_info('channel_diagnostics_publish')->{started},'explicit opt-in setup failed');
        $s->{_tasks}{channel_diagnostics_publish}{timer}->invoke_event('on_tick');
        my$path="$dir/7.json";check(-f$path && ((stat($path))[2]&0777)==0640,'publication missing or mode incorrect');
        open my$f,'<:raw',$path or die$!;my$before=do{local$/;<$f>};close$f;
        my$script=q{const {readChannelDiagnostics}=require(process.argv[1]);readChannelDiagnostics({directory:process.argv[2],id:7,name:'#test'}).then(r=>process.stdout.write(JSON.stringify(r)));};
        open my$node,'-|','node','-e',$script,abs_path('contrib/mbweb/lib/channelDiagnostics.js'),$dir or die$!;
        my$raw=do{local$/;<$node>};close$node or die 'Node contract probe failed';my$web=$json->decode($raw);
        check($web->{state} eq 'fresh' && $web->{report}{flags}{Reddit} eq 'on' && $web->{report}{plugins}{packages}[0]{name} eq 'witness','native publisher/Node contract diverged');
        check(!exists($web->{report}{activity}) && !exists($web->{report}{plugins}{loaded_v3}),'instance data crossed web scope');
        $probe->{fault}='flags.execute';check(!$publisher->tick,'invalid flag observation published');
        open$f,'<:raw',$path or die$!;check(do{local$/;<$f>} eq $before,'failed publication replaced good observation');close$f;
        $probe->{fault}='';rename($path,"$dir/original") or die$!;symlink("$dir/original",$path) or die$!;
        check(!$publisher->tick && -l$path,'symlink destination replaced');
        check(!eval{Mediabot::Diagnostics::Publisher->new(bot=>$b,directory=>$dir,channels=>['#bad name']);1},'invalid allowlist accepted');
        unlink$path;chmod 0777,$dir;check(!$publisher->tick && !-e$path,'writable directory accepted');
        my$orphan={};my$observer=Mediabot::Diagnostics::Publisher->new(bot=>$orphan,directory=>$dir,channels=>['#test']);
        undef$orphan;check(!defined($observer->{bot}) && !$observer->tick,'publisher retained or resurrected bot');
    });
    $group->('plugin inventory and private wire output remain bounded with explicit omitted observations',sub {
        my($b)=MB938ChannelDiagnosticFixture::setup();my$m=Mediabot::PluginManager->new(bot=>$b);$b->{plugin_manager}=$m;
        my$schema=Mediabot::Plugin::ConfigSchemaV3->new(schema=>{});
        for my$i(1..70){my$p=Mediabot::Plugin::ChannelPolicyV3->new(schema=>$schema);
            $m->register_plugin(name=>sprintf('test-%02d',$i),enabled=>0,metadata=>{api=>3,channel_policy=>$p})}
        my$r=collect($b);check(@{$r->{plugins}{packages}}==64 && $r->{plugins}{omitted}==6,'inventory bound absent');
        my$lines=Mediabot::Diagnostics::Channel->new(bot=>$b)->lines($r);
        check(@$lines<=24 && !grep({length($_)>400 || /[\r\n\x1b]/}@$lines),'private report exceeded bound');
        my($raw,$other)=MB938ChannelDiagnosticFixture::wire('telnet','#café',sub{manager($_[0])});
        check($raw=~/Plugin witness:/ && $other!~/Plugin witness|diagnos/,'plugin wire privacy');
    });
    return\@out;
}
unless(caller){print$json->encode([@{MB938ChannelDiagnosticFixture::run_checks()},@{MB939ActivityDiagnosticFixture::run_checks()},@{run_checks()}])}
1;
