use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP ();
use Mediabot::NetworkStats;
use Mediabot::Mediabot;

{ package MB1027::Conf; sub get { $_[0]{$_[1]} } }
{ package MB1027::IRC; sub is_connected { $_[0]{connected} } }
{ package MB1027::Metrics; sub set { $_[0]{$_[1]}=$_[2] } }

my @warnings;
local $SIG{__WARN__}=sub {push @warnings,@_};
my $dir=tempdir(CLEANUP=>1);
my $serial=0;
sub fixture_1400 {
    my $clock=1000;
    my $path="$dir/".(++$serial).'.json';
    my $conf=bless {'network_stats.ENABLED'=>1,'network_stats.OUTPUT_FILE'=>$path,
        'connection.CONN_SERVER_NETWORK'=>'Fixture'},'MB1027::Conf';
    my $exporter=Mediabot::NetworkStats->new(conf=>$conf,now=>sub {$clock});
    return ($exporter,\$clock,$path);
}
sub burst_1400 {
    my ($e)=@_;
    $e->observe('251',[],'There are 17 users and 83 invisible on 4 servers');
    $e->observe('252',[5],'');
    $e->observe('255',[],'I have 45 clients and 3 servers');
}
sub bytes_1400 { open my $f,'<:raw',$_[0] or die $!;local $/;return <$f> }
sub sample_1400 { JSON::PP->new->utf8->decode(bytes_1400($_[0])) }

{
    my ($e,$clock,$path)=fixture_1400();
    my $metrics=bless {},'MB1027::Metrics';
    my $bot=bless {network_stats_exporter=>$e,metrics=>$metrics,
        irc=>bless({connected=>1},'MB1027::IRC')},'Mediabot';
    $bot->update_network_metrics_from_numeric('251',[],'There are 17 users and 83 invisible on 4 servers');
    $bot->update_network_metrics_from_numeric('252',[5],'');
    $bot->update_network_metrics_from_numeric('255',[],'I have 45 clients and 3 servers');
    $$clock=1001;
    $bot->update_network_metrics_from_numeric('251',[],'Visibility breakdown unavailable');
    $bot->update_network_metrics_from_numeric('266',[50,80],'');
    $$clock=1004;
    my $published=$bot->flush_network_stats();
    my $s=$published ? sample_1400($path) : {};
    is_deeply([$published,$s->{sampled_at},$s->{counts},$metrics->{mediabot_network_users}],
        [1,1001,{users=>50,global_users=>50,users_max=>80},50],
        'native numeric dispatch exports the fresh total without inheriting the previous visibility, operators or local scope');
}
{
    my ($e,$clock,$path)=fixture_1400();
    burst_1400($e);$$clock=1030;
    $e->observe('251',[],'Unrecognized server text');
    $e->observe('266',[12,20],'');$$clock=1033;
    my $published=$e->flush();
    my $s=$published ? sample_1400($path) : {};
    is_deeply([$published,$s->{sampled_at},$s->{counts}],
        [1,1030,{users=>12,global_users=>12,users_max=>20}],
        'an old unfinished burst cannot cause the new total-only reply to be discarded as expired');
}
{
    my ($e,$clock,$path)=fixture_1400();
    $e->observe('251',[],'There are 1000000000 users and 2 invisible on 1 servers');
    $e->observe('252',[0],'');$e->observe('253',[0],'');$e->observe('254',[9],'');
    $e->observe('266',[5,10],'');$$clock=1003;
    my $published=$e->flush();
    my $s=$published ? sample_1400($path) : {};
    is_deeply([$published,$s->{sampled_at},$s->{counts}],
        [1,1000,{users=>5,global_users=>5,users_max=>10,operators=>0,unknown_connections=>0,channels=>9}],
        'a new burst retains its own optional counters and explicit zeros even when its 251 cannot be parsed');
}
{
    my ($e,$clock,$path)=fixture_1400();
    burst_1400($e);$$clock=1003;die 'fixture publication failed' unless $e->flush();
    my $before=bytes_1400($path);
    $$clock=1004;burst_1400($e);$$clock=1005;
    $e->observe('251',[],'Restricted reply');
    my $early=$e->flush();$$clock=1008;my $late=$e->flush();
    is_deeply([$early,$late,defined($e->{pending})?1:0,bytes_1400($path),(stat($path))[2]&0777],
        [0,0,0,$before,0600],
        'a new unparseable incomplete burst expires without republishing old counts or replacing the last confirmed file');
}
{
    my ($e,$clock,$path)=fixture_1400();
    burst_1400($e);$$clock=1001;
    $e->observe('251',[2,3,1],'Localized');
    $e->observe('252',['invalid'],'');
    $e->observe('255',[],'I have 5 clients and 0 servers');
    my $early=$e->flush();$$clock=1004;my $published=$e->flush();
    my $s=$published ? sample_1400($path) : {};
    is_deeply([$early,$published,$s->{sampled_at},$s->{counts},$e->flush()],
        [0,1,1001,{users=>5,visible_users=>2,invisible_users=>3,servers=>1,local_users=>5,local_servers=>0},0],
        'valid structured starts still isolate cycles, tolerate malformed optional replies, settle and publish once');
}
{
    my ($e,$clock,$path)=fixture_1400();
    $e->observe('251',[],'Restricted reply');$e->observe('266',[4,8],'');
    $e->reset();$$clock=1003;
    my $reset=$e->flush();
    my $off=Mediabot::NetworkStats->new(conf=>bless({},'MB1027::Conf'),now=>sub {$$clock});
    $off->observe('251',[],'Restricted reply');$off->observe('266',[4,8],'');
    is_deeply([$reset,-e $path?1:0,$off->flush(),defined($off->{pending})?1:0],
        [0,0,0,0],'disconnect reset and default-off collection still prevent publication');
}
is_deeply(\@warnings,[],'cycle boundaries and publication emit no warnings');
done_testing;
