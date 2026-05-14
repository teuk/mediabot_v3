# t/cases/222_external_claude_chanset_gate.t
# =============================================================================
# Verify claudeAI() checks the 'Claude' chanset gate before calling the API.
# Same pattern as chatGPT() checking 'chatGPT' chanset.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_222 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/; return <$fh>;
}

sub _extract_sub_222 {
    my ($src, $sub_name) = @_;
    my $re = qr/^[ \t]*sub[ \t]+\Q$sub_name\E\b[^{]*\{/m;
    return undef unless $src =~ /$re/g;
    my $start = $-[0]; my $pos = pos($src); my $depth = 1;
    while ($pos < length($src)) {
        my $ch = substr($src, $pos, 1);
        $depth++ if $ch eq '{'; $depth-- if $ch eq '}';
        return substr($src, $start, $pos + 1 - $start) if $depth == 0;
        $pos++;
    }
    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_222(File::Spec->catfile('.', 'Mediabot', 'External.pm'));

    # Claude chanset gate uses _chanset_ok helper
    my $body = _extract_sub_222($src, 'claudeAI');
    $assert->ok(defined $body && $body ne '', 'claudeAI body found');

    $assert->like($body // '', qr/_chanset_ok/,
        'claudeAI calls _chanset_ok for channel gate');

    $assert->like($body // '', qr/_chanset_ok.*Claude/,
        "claudeAI checks 'Claude' chanset specifically");

    # Must be checked BEFORE the HTTP call
    my $gate_pos = index($body // '', '_chanset_ok');
    my $http_pos = index($body // '', '->request(');
    $assert->ok($gate_pos >= 0 && $http_pos >= 0 && $gate_pos < $http_pos,
        'chanset gate comes before HTTP request in claudeAI');

    # _chanset_ok must be exported
    $assert->like($src, qr/our\s+\@EXPORT.*_chanset_ok/s,
        '_chanset_ok is in @EXPORT');

    # chatGPT also has a gate (regression check)
    my $gpt_body = _extract_sub_222($src, 'chatGPT');
    $assert->like($gpt_body // '', qr/chatGPT.*chanset|opt-in check/,
        'chatGPT still has its own chanset gate');
};
