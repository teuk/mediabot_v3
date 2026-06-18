# t/cases/167_chatgpt_json_structure_guard.t
# =============================================================================
# Regression checks for chatGPT() response parsing.
#
# decode_json() being inside eval is not enough: the decoded JSON may be valid
# but structurally unexpected, such as {error:{...}} or {choices:null}.  chatGPT()
# must verify the response shape before dereferencing choices[0].message.content.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_chatgpt_json_guard {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_chatgpt_json_guard {
    my ($src, $sub_name) = @_;

    my $start_re = qr/^sub\s+\Q$sub_name\E\s*\{/m;
    return undef unless $src =~ /$start_re/g;

    my $start = pos($src);
    my $depth = 1;
    my $pos   = $start;
    my $len   = length($src);

    while ($pos < $len) {
        my $char = substr($src, $pos, 1);

        if ($char eq '{') {
            $depth++;
        }
        elsif ($char eq '}') {
            $depth--;

            if ($depth == 0) {
                return substr($src, $start, $pos - $start);
            }
        }

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_chatgpt_json_guard(
        File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm')
    );

    my $body = _extract_sub_body_chatgpt_json_guard($src, 'chatGPT');

    $assert->ok(
        defined $body,
        'chatGPT body found'
    );

    $assert->like(
        $body // '',
        qr/my \$data = eval \{ decode_json\(\$response\) \};/,
        'chatGPT still decodes JSON under eval'
    );

    $assert->like(
        $body // '',
        qr/my \$answer;/,
        'chatGPT stores extracted content in a guarded answer variable'
    );

    $assert->like(
        $body // '',
        qr/ref\(\$data\) eq 'HASH'/,
        'chatGPT verifies decoded response is a HASH'
    );

    $assert->like(
        $body // '',
        qr/ref\(\$data->\{choices\}\) eq 'ARRAY'/,
        'chatGPT verifies choices is an ARRAY before dereferencing'
    );

    $assert->like(
        $body // '',
        qr/ref\(\$data->\{choices\}\[0\]\) eq 'HASH'/,
        'chatGPT verifies choices[0] is a HASH'
    );

    $assert->like(
        $body // '',
        qr/ref\(\$data->\{choices\}\[0\]\{message\}\) eq 'HASH'/,
        'chatGPT verifies message is a HASH'
    );

    $assert->like(
        $body // '',
        qr/defined\(\$data->\{choices\}\[0\]\{message\}\{content\}\)/,
        'chatGPT verifies content is defined'
    );

    $assert->like(
        $body // '',
        qr/if \(\$\@ \|\| !defined\(\$answer\) \|\| \$answer eq ''\)/,
        'chatGPT handles decode errors and missing content safely'
    );

    $assert->unlike(
        $body // '',
        qr/if \(\$\@ \|\| !\(\$data->\{choices\}\[0\]\{message\}\{content\} \|\| ''\)\)/,
        'chatGPT no longer dereferences choices content in the error condition'
    );

    $assert->unlike(
        $body // '',
        qr/my \$answer = \$data->\{choices\}\[0\]\{message\}\{content\};/,
        'chatGPT no longer assigns answer through an unguarded direct dereference'
    );
};
