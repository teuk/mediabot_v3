# t/cases/578_mb359_claude_content_blocks_parsing.t
# Anthropic multi-content-block parsing regression, provider-owned since MB699.
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use Mediabot::AI::Provider::Anthropic ();
sub _s578 { my($p)=@_; open my$f,'<:raw',$p or die$!; local$/; <$f> }
return sub {
    my($assert)=@_;
    my $provider=_s578(File::Spec->catfile('.','Mediabot','AI','Provider','Anthropic.pm'));
    my $external=_s578(File::Spec->catfile('.','Mediabot','External','Claude.pm'));
    $assert->like($provider, qr/for my \$blk \(@\{ \$data->\{content\} \}\)/, 'provider iterates all content blocks');
    $assert->like($provider, qr/\(\$blk->\{type\} \/\/ ''\) eq 'text'/, 'provider selects text blocks');
    $assert->like($provider, qr/my \$joined = join\('', \@texts\)/, 'provider joins text blocks in order');
    $assert->is(Mediabot::AI::Provider::Anthropic::extract_answer('{"content":[{"type":"text","text":"hello "},{"type":"tool_use","id":"x"},{"type":"text","text":"world"}]}'), 'hello world', 'text blocks are joined and non-text ignored');
    $assert->unlike($external, qr/for my \$blk .*?\{content\}/s, 'caller no longer parses Anthropic content blocks');
};
