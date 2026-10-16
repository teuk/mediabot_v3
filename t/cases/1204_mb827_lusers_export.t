use strict;
use warnings;
use File::Temp qw(tempdir);
use JSON::PP ();
use Mediabot::NetworkStats qw(parse_numeric);
use Mediabot::Mediabot;

{package Conf1204; sub get {$_[0]->{$_[1]}}}
{package IRC1204; sub is_connected {$_[0]->{connected}}}
{package Metric1204; sub set {$_[0]->{$_[1]}=$_[2]}}

return sub {
    my ($a)=@_;
    my $dir=tempdir(CLEANUP=>1);my $clock=1700000000;
    my $path="$dir/stats.json";
    my $conf=bless {'network_stats.ENABLED'=>1,'network_stats.OUTPUT_FILE'=>$path,'connection.CONN_SERVER_NETWORK'=>'Test network'},'Conf1204';
    my $r=Mediabot::NetworkStats->new(conf=>$conf,now=>sub{$clock});
    my $short=Mediabot::NetworkStats->new(conf=>bless({'main.LUSERS_REFRESH'=>1},'Conf1204'));
    $a->ok($short->{interval}==60,'mb827: advertised cadence follows the core polling lower bound');
    my $v=parse_numeric('251',[],'There are 17 users and 83 invisible on 4 servers');
    $a->ok($v->{visible_users}==17 && $v->{invisible_users}==83 && $v->{users}==100 && $v->{servers}==4,'mb827: visible/invisible actual split');
    $a->ok(!keys %{parse_numeric('251',[],'There are -1 users and 8 invisible on 4 servers')},'mb827: negative text refused');
    $a->ok(!keys %{parse_numeric('252',['9bad'],'ignored')},'mb827: malformed positional count refused');
    $a->ok(parse_numeric('251',[2,3,4],'localized')->{users}==5,'mb827: structured counts supported');
    for my $n (qw(252 253 254)) {$a->ok(scalar(keys %{parse_numeric($n,[0],'localized')})==1,"mb827: explicit zero numeric $n preserved");}
    $a->ok(parse_numeric('255',[],'I have 45 clients and 3 servers')->{local_users}==45,'mb827: local clients distinct from network total');
    $a->ok(parse_numeric('265',[45,90],'')->{local_users_max}==90,'mb827: local maximum');
    $a->ok(parse_numeric('266',[],'Current global users: 100 Max: 200')->{global_users}==100,'mb827: textual global total');
    $r->observe('254',[99],'');$clock+=3;
    $a->ok(!$r->flush && !-e $path,'mb827: orphan numeric cannot publish a mixed cycle');
    $r->observe('251',[],'There are 17 users and 83 invisible on 4 servers');
    $r->observe('252',[5],'operator(s) online');$r->observe('253',[0],'unknown connections');$r->observe('254',[22],'channels');
    $r->observe('255',[],'I have 45 clients and 3 servers');$r->observe('265',[45,90],'');$r->observe('266',[101,200],'');
    $a->ok(!$r->flush && !-e $path,'mb827: wait for reply burst to settle');$clock+=3;
    $a->ok($r->flush && -f $path,'mb827: settled reply publishes once');
    open my $fh,'<:raw',$path or die $!;local $/;my $raw=<$fh>;close $fh;
    my $s=JSON::PP->new->utf8->decode($raw);
    $a->ok($s->{schema}==1 && $s->{network} eq 'Test network' && $s->{sampled_at}==$clock-3,'mb827: aggregate protocol and original sample time');
    $a->ok($s->{counts}{users}==100 && $s->{counts}{global_users}==101 && $s->{counts}{local_users}==45,'mb827: preserve differing scopes without fabricating split');
    $a->ok($s->{counts}{unknown_connections}==0,'mb827: explicit zero exported');
    $a->ok((stat($path))[2]%512==384,'mb827: snapshot private mode 0600');
    $a->ok($raw !~ /operator\(s\)|clients|secret|API_KEY/,'mb827: raw lines/configuration never exported');
    $a->ok(!$r->flush,'mb827: no periodic duplicate/flatline sample without new LUSERS');
    $r->observe('251',[],'There are 4 users and 6 invisible on 1 servers');$r->observe('255',[],'I have 10 clients and 0 servers');$clock+=3;$r->flush;
    open $fh,'<:raw',$path or die $!;$s=JSON::PP->new->utf8->decode(<$fh>);close $fh;
    $a->ok(!exists($s->{counts}{operators}) && !exists($s->{counts}{channels}) && !exists($s->{counts}{users_max}),'mb827: optional absent values never carried across cycles');
    $r->observe('251',[],'There are 1 users and 1 invisible on 1 servers');$r->observe('255',[],'I have 2 clients and 0 servers');$r->reset;$clock+=3;
    $a->ok(!$r->flush,'mb827: disconnect/reconnect clears incomplete observation');
    $r->observe('251',[],'There are 1 users and 1 invisible on 1 servers');$r->observe('255',[],'I have 2 clients and 0 servers');$clock+=30;
    $a->ok(!$r->flush,'mb827: late cycle is discarded');
    $r->observe('266',['50','80'],'');$clock+=3;
    $a->ok($r->flush,'mb827: global total works when the visibility breakdown is unavailable');
    open $fh,'<:raw',$path or die $!;$s=JSON::PP->new->utf8->decode(<$fh>);close $fh;
    $a->ok($s->{counts}{users}==50 && !exists($s->{counts}{visible_users}),'mb827: total-only fallback never fabricates visible users');
    my $off=Mediabot::NetworkStats->new(conf=>bless({},'Conf1204'),now=>sub{$clock});$off->observe('251',[],'There are 1 users and 1 invisible on 1 servers');$clock+=3;
    $a->ok(!$off->flush,'mb827: disabled by default');
    unlink $path;symlink "$dir/victim",$path or die $!;
    $r->observe('251',[],'There are 1 users and 1 invisible on 1 servers');$r->observe('255',[],'I have 2 clients and 0 servers');$clock+=3;
    $a->ok(!$r->flush && !-e "$dir/victim",'mb827: symlink output refused without modifying target');unlink $path;
    my $metrics=bless {},'Metric1204';my $bot=bless {conf=>$conf,network_stats_exporter=>$r,metrics=>$metrics,irc=>bless({connected=>1},'IRC1204')},'Mediabot';
    $bot->update_network_metrics_from_numeric('251',[],'There are 7 users and 3 invisible on 2 servers');
    $bot->update_network_metrics_from_numeric('255',[],'I have 6 clients and 1 servers');$bot->update_network_metrics_from_numeric('265',[6,9],'');$bot->update_network_metrics_from_numeric('266',[10,20],'');$clock+=3;
    $a->ok($bot->flush_network_stats && -f $path,'mb827: actual core numeric path and tick export connected');
    $a->ok($metrics->{mediabot_network_visible_users}==7 && $metrics->{mediabot_network_local_users_max}==9 && $metrics->{mediabot_network_users}==10,'mb827: new Prometheus gauges preserve existing total precedence');
    $bot->{irc}{connected}=0;$r->observe('251',[],'There are 1 users and 1 invisible on 1 servers');$clock+=3;
    $a->ok(!$bot->flush_network_stats && !$r->{pending},'mb827: disconnected core drops pending cycle');
    open $fh,'<','mediabot.pl' or die $!;my $src=<$fh>;close $fh;
    for my $n (253,255) {$a->like($src,qr/on_message_$n\s+=>\s*\\&on_message_$n/,"mb827: numeric $n wired into actual IRC dispatch");}
};
