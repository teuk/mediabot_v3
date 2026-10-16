#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Getopt::Long qw(GetOptions);
use JSON::PP ();
use Mediabot::Conf;
use Mediabot::AI qw(provider_configured normalize_provider);
use Mediabot::AI::Client;
use Mediabot::AI::Request qw(build_request);
use Mediabot::AI::MetaPolicy qw(settings clean);
use Mediabot::AI::MetaReply qw(shorturl_ready);
my ($file,$live,$help,$only,$model,$list)=('mediabot.conf',0,0,'','',0);
GetOptions('conf=s'=>\$file,'live'=>\$live,'help'=>\$help,'provider=s'=>\$only,
    'model=s'=>\$model,'list-gemini-models'=>\$list) or exit 2;
if ($help) {print "Usage: perl tools/meta_ai_check.pl --conf mediabot.conf [--live] [--provider gemini] [--model ID]\n";
    print "Default: offline configuration check. --live: one small paid test per selected contributor; Gemini may retry once within its request deadline; no IRC, web search or memory write.\n";
    print "--provider checks that provider even when absent from meta_ai.PROVIDERS; --model is probe-only and requires --provider.\n";
    print "--live --list-gemini-models lists up to 100 advertised text-generation models from Google's fixed endpoint; listing is not an access/billing guarantee.\n";exit 0}
if (length($only)) {$only=normalize_provider($only)//'';die "[KO] Unknown explicit provider.\n" unless $only && $only ne 'auto'}
die "[KO] --model requires --provider and a valid model ID.\n"
    if length($model) && (!length($only) || $model !~ /\A[A-Za-z0-9][A-Za-z0-9._:-]{0,119}\z/);
die "[KO] --list-gemini-models requires --live and cannot be combined with --provider/--model.\n"
    if $list && (!$live || length($only) || length($model));
-d $file and die "[KO] Configuration path is a directory.\n";
my @stat=stat($file);
die "[KO] Configuration must be a readable regular file with mode 0600.\n"
    unless @stat && -f $file && -r $file && ($stat[2]&0777)==0600;
my $conf=eval {Mediabot::Conf->new({},$file)};
die "[KO] Configuration cannot be parsed.\n" unless $conf;
my $cfg=settings($conf);my $failures=0;my $configured=0;
sub gemini_failure {
    my ($r)=@_;
    my $category=$r->{failure_category}//Mediabot::AI::Provider::Gemini::failure_category(
        $r->{status},$r->{error_type},$r->{error_code},$r->{reason});
    $category='unknown' unless $category =~ /\A(?:quota|access|model|request|output_budget|service_unavailable|server_error|timeout|tls|dns|connection|transport|response|http_error)\z/;
    my $type=$r->{error_type}//'';
    $type='unknown' unless $type =~ /\A(?:INVALID_ARGUMENT|FAILED_PRECONDITION|RESOURCE_EXHAUSTED|UNAUTHENTICATED|PERMISSION_DENIED|NOT_FOUND|INTERNAL|UNAVAILABLE|DEADLINE_EXCEEDED|MAX_TOKENS|SAFETY|RECITATION)\z/;
    my $code=$r->{error_code}//'';$code='none' unless $code =~ /\A\d{1,3}\z/;
    print "  Gemini category=$category api_status=$type api_code=$code retries=",0+($r->{transient_retries}//0),"\n";
    print '  ',Mediabot::AI::Provider::Gemini::user_error_message($r->{status},$type,$code),"\n";
}
if ($list) {
    require HTTP::Tiny;
    my $key=$conf->get('gemini.API_KEY');
    die "[KO] Gemini key missing.\n" unless defined($key) && !ref($key) && length($key);
    my $r=HTTP::Tiny->new(timeout=>20,verify_SSL=>1,max_redirect=>0,max_size=>1024*1024)->get(
        'https://generativelanguage.googleapis.com/v1beta/models?pageSize=100',
        {headers=>Mediabot::AI::Provider::Gemini::build_headers({api_key=>$key})});
    unless ($r->{success}) {
        my ($type,$code)=Mediabot::AI::Provider::Gemini::extract_error($r->{content});
        print '[KO] Gemini model listing HTTP=',0+($r->{status}//0),"\n";
        gemini_failure({status=>$r->{status},error_type=>$type,error_code=>$code,reason=>$r->{reason},
            failure_category=>Mediabot::AI::Provider::Gemini::failure_category($r->{status},$type,$code,$r->{reason},$r->{content})});exit 1;
    }
    my $data=eval {JSON::PP::decode_json($r->{content})};
    die "[KO] Invalid model listing response.\n" unless ref($data) eq 'HASH' && ref($data->{models}) eq 'ARRAY';
    my %ids;my $count=0;
    for my $row (@{$data->{models}}) {
        last if $count++>=100;
        next unless ref($row) eq 'HASH' && ref($row->{supportedGenerationMethods}) eq 'ARRAY'
            && grep {!ref($_) && defined($_) && $_ eq 'generateContent'} @{$row->{supportedGenerationMethods}};
        my $id=$row->{name};next unless defined($id) && !ref($id) && $id =~ s{\Amodels/(gemini-[A-Za-z0-9._-]{1,110})\z}{$1};
        next if $id =~ /audio|image|tts|live|robotics|embedding/i;$ids{$id}=1;
    }
    print "$_\n" for sort keys %ids;
    print "[NOTE] Listing is advertised capability; validate the chosen model with --provider gemini --model ID --live.\n";
    print "[NOTE] More models exist beyond this first page.\n" if $data->{nextPageToken};
    exit 0;
}
$cfg->{models}{$only}=$model if length($model);
print "[PROBE] Explicit provider=$only; private configuration and activation unchanged.\n" if length($only);
print "Mode: ",($cfg->{enabled}?'enabled':'disabled')," | pilot channels: ",scalar(keys %{$cfg->{channels}}),"\n";
print "Limits: $cfg->{rate_max}/min/channel; $cfg->{global_rate_max}/min/instance; $cfg->{daily_limit}/UTC day\n";
my %overrides=('openai.API_URL'=>'https://api.openai.com/v1/responses',
    'openai.FALLBACK_MODEL'=>'','gemini.THINKING_LEVEL'=>'LOW',
    map {($_.'.MODEL'=>$cfg->{models}{$_})} keys %{$cfg->{models}});
my $client=Mediabot::AI::Client->new(conf=>$conf,config_overrides=>\%overrides);
for my $provider (length($only)?($only):@{$cfg->{providers}}) {
    my $model=$cfg->{models}{$provider};
    unless (defined($model) && $model =~ /^[a-zA-Z0-9._:-]{1,120}$/) {
        print "[KO] $provider model identifier is invalid.\n";$failures++;next;
    }
    my $present=provider_configured($conf,$provider);
    print "[$provider] model=$model | key=",($present?'configured':'missing'),"\n";
    unless ($present) {$failures++ if length($only);next}$configured++;
    next unless $live;
    my $result=$client->execute(build_request(provider=>$provider,purpose=>'meta_probe',
        system=>'Reply briefly.',messages=>[{role=>'user',content=>'Reply with OK.'}],
        max_output_tokens=>1024,timeout_seconds=>$cfg->{timeout}));
    if ($result->{ok}) {print "[OK] $provider live response received.",
        $provider eq 'gemini'?' retries='.(0+($result->{transient_retries}//0)):'',"\n"}
    else {
        my $code=clean($result->{error},80);$code='request_failed' unless $code =~ /^[a-z0-9_]+$/;
        my $status=0+($result->{status}//0);
        print "[KO] $provider $code status=$status.",
            $provider eq 'gemini'?'':' Check project/model access and billing in its console.',"\n";
        gemini_failure($result) if $provider eq 'gemini';$failures++;
    }
}
if (!length($only) && $configured<$cfg->{min_providers}) {print "[KO] Fewer than $cfg->{min_providers} configured contributors.\n";$failures++}
print "Web: $cfg->{web} | Tavily key=",(length(clean($conf->get('tavily.API_KEY'),500))?'configured':'missing'),
    " | native OpenAI fallback=",(provider_configured($conf,'openai')?'available for live acceptance':'unconfigured'),"\n";
print "Legacy OpenAI model: ",clean($conf->get('openai.MODEL')//'gpt-4o-mini',120),"\n";
print 'ShortURL: ',(shorturl_ready({conf=>$conf})?'configured (private service)':'unconfigured/invalid; original-source fallback'),
    " | researched replies: up to 2 answer lines + 1 sources line\n";
print "No general OpenAI key-expiry deadline is established; check the account and active model separately.\n";
print "[OK] ",($live?'Provider acceptance checks':'Offline check')," completed. Nothing deployed, sent to IRC or written to memory.\n" unless $failures;
exit($failures?1:0);
