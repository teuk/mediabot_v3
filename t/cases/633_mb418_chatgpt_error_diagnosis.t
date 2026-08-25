# t/cases/633_mb418_chatgpt_error_diagnosis.t
# OpenAI error parsing/classification lives in Provider::OpenAI; model fallback
# eligibility lives in AI::Client.
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use Mediabot::AI::Provider::OpenAI ();
sub _s633 { my($p)=@_; open my$f,'<:raw',$p or die$!; local$/; <$f> }
return sub {
    my($assert)=@_;
    my $external=_s633(File::Spec->catfile('.','Mediabot','External','Claude.pm'));
    my $provider=_s633(File::Spec->catfile('.','Mediabot','AI','Provider','OpenAI.pm'));
    my $client=_s633(File::Spec->catfile('.','Mediabot','AI','Client.pm'));
    $assert->like($provider, qr/sub extract_error\s*\{/, 'provider owns structured error parsing');
    $assert->like($provider, qr/sub user_error_message\s*\{/, 'provider owns actionable diagnosis');
    $assert->like($client, qr/sub _openai_fallback_worthy\s*\{/, 'client owns model fallback eligibility');
    $assert->like($client, qr/\$status == 429 && !\$quota/, 'quota-exhausted 429 is excluded from fallback');
    $assert->like($external, qr/sub _chatgpt_error_cause\s*\{.*?Provider::OpenAI::extract_error/s, 'compatibility error wrapper delegates to provider');
    $assert->like($external, qr/sub _chatgpt_user_error_message\s*\{.*?Provider::OpenAI::user_error_message/s, 'compatibility user-message wrapper delegates to provider');
    my($t,$c,$m)=Mediabot::AI::Provider::OpenAI::extract_error('{"error":{"type":"rate_limit_error","code":"insufficient_quota","message":"quota"}}');
    $assert->is($t,'rate_limit_error','error type parsed');
    $assert->is($c,'insufficient_quota','error code parsed');
    $assert->like(Mediabot::AI::Provider::OpenAI::user_error_message(429,$t,$c), qr/credits|budget/i, 'quota diagnosis is actionable');
};
