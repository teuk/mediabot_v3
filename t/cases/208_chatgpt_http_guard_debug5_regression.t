# t/cases/208_chatgpt_http_guard_debug5_regression.t
# HTTP exception guarding now belongs to AI::Transport; verbose prompt/answer
# logging remains DEBUG5 in the caller.
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
sub _s208 { my($p)=@_; open my$f,'<:raw',$p or die$!; local$/; <$f> }
return sub {
    my($assert)=@_;
    my $external=_s208(File::Spec->catfile('.','Mediabot','External','Claude.pm'));
    my $transport=_s208(File::Spec->catfile('.','Mediabot','AI','Transport.pm'));
    my $client=_s208(File::Spec->catfile('.','Mediabot','AI','Client.pm'));

    $assert->like($transport, qr/my \$res = eval \{.*?\$http->request/s, 'shared transport catches HTTP request exceptions');
    $assert->like($transport, qr/reason\s*=>\s*_clean_reason\(\$reason\)/, 'transport sanitizes exception reason');
    $assert->like($client, qr/Mediabot::AI::Transport::post_json\(/, 'AI client routes provider HTTP through shared transport');
    $assert->like($external, qr/log\(5,"chatGPT\(\) chatGPT prompt: \$prompt"\)/, 'tellme prompt remains DEBUG5');
    $assert->like($external, qr/log\(5, "chatGPT\(\) chatGPT raw answer: \$answer"\)/, 'tellme raw answer remains DEBUG5');
    $assert->unlike($external, qr/log\([34],"chatGPT\(\) chatGPT prompt:/, 'tellme prompt not logged at DEBUG3/4');
};
