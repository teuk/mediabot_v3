use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
use IPC::Open3;
use Symbol qw(gensym);
my $tmp=tempdir(CLEANUP=>1);my $conf="$tmp/bot.conf";
open my $fh,'>',$conf or die $!;
print {$fh} "[meta_ai]\nPROVIDERS=openai anthropic\n[openai]\nAPI_KEY=YOUR_OPENAI_TEST_KEY\n[anthropic]\nAPI_KEY=YOUR_CLAUDE_TEST_KEY\n[gemini]\nAPI_KEY=YOUR_GEMINI_TEST_KEY\n";
close $fh;chmod 0600,$conf;
open $fh,'>',"$tmp/MB822ProbeBootstrap.pm" or die $!;
print {$fh} <<'MODULE';
package MB822ProbeBootstrap;
use strict;
use warnings;
use Mediabot::AI::Client;
use HTTP::Tiny;
use JSON::PP;
no warnings 'redefine';
*Mediabot::AI::Client::execute=sub {
    my ($self,$r)=@_;
    die 'unexpected provider' unless $r->{provider} eq 'gemini';
    if ($ENV{MB822_PROBE_FAIL}) {return {ok=>0,error=>'http_error',status=>599,failure_category=>'tls',
        error_type=>'UNTRUSTED_PRIVATE_TOKEN',error_message=>'DO_NOT_PRINT_BODY',reason=>'DO_NOT_PRINT_REASON'}}
    die 'model override not propagated' if $ENV{MB822_OVERRIDE}
        && $self->{config_overrides}{'gemini.MODEL'} ne 'gemini-2.5-flash';
    return {ok=>1,status=>200,answer=>'DO_NOT_PRINT_ANSWER',transient_retries=>1};
};
*HTTP::Tiny::get=sub {
    my ($self,$url,$opts)=@_;
    die 'unexpected model endpoint' unless $url eq 'https://generativelanguage.googleapis.com/v1beta/models?pageSize=100';
    die 'missing header authentication' unless $opts->{headers}{'x-goog-api-key'} eq 'YOUR_GEMINI_TEST_KEY';
    return {success=>1,status=>200,content=>JSON::PP::encode_json({models=>[
        {name=>'models/gemini-3.8-flash',supportedGenerationMethods=>['generateContent']},
        {name=>'models/gemini-2.5-flash',supportedGenerationMethods=>['generateContent']},
        {name=>'models/gemini-image-preview',supportedGenerationMethods=>['generateContent']},
        {name=>'models/DO_NOT_PRINT_PRIVATE',supportedGenerationMethods=>['generateContent']},
        {name=>'models/gemini-embedding',supportedGenerationMethods=>['embedContent']}],nextPageToken=>'DO_NOT_PRINT_PAGE_TOKEN'})};
};
1;
MODULE
close $fh;
sub check {
    my (@args)=@_;my $err=gensym;
    local $ENV{PERL5LIB}=join(':',$tmp,abs_path('.'),$ENV{PERL5LIB}//'');
    local $ENV{PERL5OPT}='-MMB822ProbeBootstrap';
    my $pid=open3(undef,my $out,$err,$^X,'tools/meta_ai_check.pl','--conf',$conf,@args);
    local $/;my $text=(<$out>//'').(<$err>//'');waitpid($pid,0);return ($?>>8,$text);
}
my ($exit,$text)=check('--provider','gemini');
is($exit,0,'offline Gemini inspection works outside the active provider list');
like($text,qr/Explicit provider=gemini/,'probe does not pretend activation occurred');
like($text,qr/\[gemini\] model=/,'explicit check includes Gemini');
unlike($text,qr/\[openai\] model=|\[anthropic\] model=/,'other providers are not retried');
($exit,$text)=check('--provider','gemini','--live');
is($exit,0,'one-provider live check can succeed');
like($text,qr/live response received[.] retries=1/,'recovery is visible without HTTP bodies');
{local $ENV{MB822_OVERRIDE}=1;($exit,$text)=check('--provider','gemini','--model','gemini-2.5-flash','--live')}
is($exit,0,'explicit model override reaches only the in-memory probe client');
like($text,qr/\[gemini\] model=gemini-2.5-flash/,'chosen probe model is reported');
{local $ENV{MB822_PROBE_FAIL}=1;($exit,$text)=check('--provider','gemini','--live')}
ok($exit!=0,'transport failure remains a failed probe');
like($text,qr/category=tls api_status=unknown/,'599 is reported with a safe transport category');
unlike($text,qr/DO_NOT_PRINT|UNTRUSTED_PRIVATE_TOKEN|YOUR_GEMINI_TEST_KEY/,'probe never dumps private data or arbitrary provider error strings');
($exit,$text)=check('--list-gemini-models','--live');
is($exit,0,'advertised Gemini models can be listed separately');
like($text,qr/^gemini-3[.]8-flash$/m,'supported text model included');
like($text,qr/^gemini-2[.]5-flash$/m,'alternative text model included without automatic selection');
unlike($text,qr/DO_NOT_PRINT|gemini-image|gemini-embedding|YOUR_GEMINI_TEST_KEY/,'listing omits unrelated models, opaque tokens and credentials');
like($text,qr/More models exist/,'bounded listing reports truncation honestly');
($exit,$text)=check('--list-gemini-models');
ok($exit!=0,'model listing cannot make network requests without explicit live mode');
($exit,$text)=check('--model','gemini-2.5-flash');
ok($exit!=0,'model override cannot ambiguously affect multiple providers');
open $fh,'<',$conf or die $!;{local $/;my $now=<$fh>;unlike($now,qr/GEMINI_MODEL|ENABLED=1/,'private configuration is not changed by any probe')};close $fh;
done_testing;
