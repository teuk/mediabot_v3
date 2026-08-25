# t/cases/634_mb419_openai_actionable_diagnosis.t
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use Mediabot::AI::Provider::OpenAI ();
sub _s634 { my($p)=@_; open my$f,'<:raw',$p or die$!; local$/; <$f> }
return sub {
    my($assert)=@_;
    my $provider=_s634(File::Spec->catfile('.','Mediabot','AI','Provider','OpenAI.pm'));
    my $client=_s634(File::Spec->catfile('.','Mediabot','AI','Client.pm'));
    $assert->like($client, qr/_conf_int\('openai\.TIMEOUT'.*?5, 60\)/s, 'client reads bounded OpenAI timeout');
    $assert->like($client, qr/timeout\s*=>\s*0 \+ \$timeout/, 'configured timeout reaches transport attempt');
    $assert->like($provider, qr/invalid_api_key|authentication/, 'provider diagnoses authentication failure');
    $assert->like($provider, qr/permission|access_denied/, 'provider diagnoses permission failure');
    $assert->like($provider, qr/model_not_found/, 'provider diagnoses model failure');
    $assert->like($provider, qr/OpenAI service error/, 'provider diagnoses server failure');
    $assert->like(Mediabot::AI::Provider::OpenAI::user_error_message(401,'authentication_error','invalid_api_key'), qr/replace openai\.API_KEY/i, '401 message is actionable');
    $assert->like(Mediabot::AI::Provider::OpenAI::user_error_message(404,'invalid_request_error','model_not_found'), qr/openai\.MODEL/i, '404 message names model config');
};
