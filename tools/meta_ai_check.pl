#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Getopt::Long qw(GetOptions);
use Mediabot::Conf;
use Mediabot::AI qw(provider_configured);
use Mediabot::AI::Client;
use Mediabot::AI::Request qw(build_request);
use Mediabot::AI::MetaPolicy qw(settings clean);
use Mediabot::AI::MetaReply qw(shorturl_ready);
my ($file,$live,$help)=('mediabot.conf',0,0);
GetOptions('conf=s'=>\$file,'live'=>\$live,'help'=>\$help) or exit 2;
if ($help) {print "Usage: perl tools/meta_ai_check.pl --conf mediabot.conf [--live]\n";
    print "Default: offline configuration check. --live: one small paid test per configured contributor; no IRC, web search or memory write.\n";exit 0}
-d $file and die "[KO] Configuration path is a directory.\n";
my @stat=stat($file);
die "[KO] Configuration must be a readable regular file with mode 0600.\n"
    unless @stat && -f $file && -r $file && ($stat[2]&0777)==0600;
my $conf=eval {Mediabot::Conf->new({},$file)};
die "[KO] Configuration cannot be parsed.\n" unless $conf;
my $cfg=settings($conf);my $failures=0;my $configured=0;
print "Mode: ",($cfg->{enabled}?'enabled':'disabled')," | pilot channels: ",scalar(keys %{$cfg->{channels}}),"\n";
print "Limits: $cfg->{rate_max}/min/channel; $cfg->{global_rate_max}/min/instance; $cfg->{daily_limit}/UTC day\n";
my %overrides=('openai.API_URL'=>'https://api.openai.com/v1/responses',
    'openai.FALLBACK_MODEL'=>'','gemini.THINKING_LEVEL'=>'LOW',
    map {($_.'.MODEL'=>$cfg->{models}{$_})} keys %{$cfg->{models}});
my $client=Mediabot::AI::Client->new(conf=>$conf,config_overrides=>\%overrides);
for my $provider (@{$cfg->{providers}}) {
    my $model=$cfg->{models}{$provider};
    unless (defined($model) && $model =~ /^[a-zA-Z0-9._:-]{1,120}$/) {
        print "[KO] $provider model identifier is invalid.\n";$failures++;next;
    }
    my $present=provider_configured($conf,$provider);
    print "[$provider] model=$model | key=",($present?'configured':'missing'),"\n";
    next unless $present;$configured++;
    next unless $live;
    my $result=$client->execute(build_request(provider=>$provider,purpose=>'meta_probe',
        system=>'Reply briefly.',messages=>[{role=>'user',content=>'Reply with OK.'}],
        max_output_tokens=>1024,timeout_seconds=>$cfg->{timeout}));
    if ($result->{ok}) {print "[OK] $provider live response received.\n"}
    else {
        my $code=clean($result->{error},80);$code='request_failed' unless $code =~ /^[a-z0-9_]+$/;
        my $status=0+($result->{status}//0);
        print "[KO] $provider $code status=$status. Check project/model access and billing in its console.\n";$failures++;
    }
}
if ($configured<$cfg->{min_providers}) {print "[KO] Fewer than $cfg->{min_providers} configured contributors.\n";$failures++}
print "Web: $cfg->{web} | Tavily key=",(length(clean($conf->get('tavily.API_KEY'),500))?'configured':'missing'),
    " | native OpenAI fallback=",(provider_configured($conf,'openai')?'available for live acceptance':'unconfigured'),"\n";
print "Legacy OpenAI model: ",clean($conf->get('openai.MODEL')//'gpt-4o-mini',120),"\n";
print 'ShortURL: ',(shorturl_ready({conf=>$conf})?'configured (private service)':'unconfigured/invalid; original-source fallback'),
    " | researched replies: up to 2 answer lines + 1 sources line\n";
print "No general OpenAI key-expiry deadline is established; check the account and active model separately.\n";
print "[OK] ",($live?'Provider acceptance checks':'Offline check')," completed. Nothing deployed, sent to IRC or written to memory.\n" unless $failures;
exit($failures?1:0);
