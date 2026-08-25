# t/cases/182_openai_fallback_model.t
# OpenAI fallback planning and eligibility are owned by Mediabot::AI::Client.
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
sub _s182 { my($p)=@_; open my$f,'<:raw',$p or die$!; local$/; <$f> }
return sub {
    my($assert)=@_;
    my $external=_s182(File::Spec->catfile('.','Mediabot','External','Claude.pm'));
    my $client=_s182(File::Spec->catfile('.','Mediabot','AI','Client.pm'));
    my $admin=_s182(File::Spec->catfile('.','Mediabot','AdminCommands.pm'));
    my $sample=_s182('mediabot.sample.conf');

    $assert->like($external, qr/openai\.FALLBACK_MODEL/, 'tellme reads fallback model');
    $assert->like($external, qr/Mediabot::AI::Client->new\(/, 'tellme delegates fallback execution to AI client');
    $assert->like($client, qr/my \@models = \(\$model\)/, 'client creates OpenAI model attempt list');
    $assert->like($client, qr/push \@models, \$fallback/, 'client adds configured fallback model');
    $assert->like($client, qr/sub _openai_fallback_worthy\s*\{/, 'client owns fallback eligibility');
    $assert->like($client, qr/\$status == 400/, 'HTTP 400 fallback eligible');
    $assert->like($client, qr/\$status == 403/, 'HTTP 403 fallback eligible');
    $assert->like($client, qr/\$status == 404/, 'HTTP 404 fallback eligible');
    $assert->like($client, qr/\$status == 429 && !\$quota/, 'transient 429 fallback eligible, quota excluded');
    $assert->like($client, qr/model_fallback\s*=>\s*\$attempt_index/, 'normalized result records model fallback');
    $assert->like($external, qr/if \(\$result->\{model_fallback\}\)/, 'caller logs successful fallback from normalized result');
    $assert->like($admin, qr/fallback_model => \{/, 'admin exposes fallback model');
    $assert->like($admin, qr/openai\.FALLBACK_MODEL/, 'admin maps fallback model config');
    $assert->like($sample, qr/^FALLBACK_MODEL=/m, 'sample documents FALLBACK_MODEL');
};
