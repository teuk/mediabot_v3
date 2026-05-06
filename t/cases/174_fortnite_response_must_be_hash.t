# t/cases/174_fortnite_response_must_be_hash.t
# =============================================================================
# Regression checks for fortniteStats_ctx().
#
# decode_json() can return valid JSON that is not a HASH, for example an ARRAY
# or a scalar. fortniteStats_ctx() must verify the decoded response is a HASH
# before accessing $data->{status} or $data->{data}.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_fortnite_response_hash {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_fortnite_response_hash {
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

    my $src = _slurp_fortnite_response_hash(
        File::Spec->catfile('.', 'Mediabot', 'External.pm')
    );

    my $body = _extract_sub_body_fortnite_response_hash($src, 'fortniteStats_ctx');

    $assert->ok(
        defined $body,
        'fortniteStats_ctx body found'
    );

    $assert->like(
        $body // '',
        qr/my \$data = eval \{ decode_json\(\$json_details\) \};/,
        'fortniteStats_ctx still decodes JSON under eval'
    );

    $assert->like(
        $body // '',
        qr/if \(\$\@ \|\| ref\(\$data\) ne 'HASH'\)/,
        'fortniteStats_ctx requires decoded API response to be a HASH'
    );

    $assert->like(
        $body // '',
        qr/JSON decode\/structure error/,
        'fortniteStats_ctx logs decode or structure errors'
    );

    $assert->like(
        $body // '',
        qr/if \(exists \$data->\{status\} && \$data->\{status\} != 200\)/,
        'fortniteStats_ctx can check API status after the HASH guard'
    );

    $assert->like(
        $body // '',
        qr/my \$payload = \$data->\{data\};/,
        'fortniteStats_ctx reads data payload only after the HASH guard'
    );

    $assert->unlike(
        $body // '',
        qr/if \(\$\@ \|\| !\$data\)/,
        'fortniteStats_ctx no longer accepts any truthy decoded reference'
    );

    $assert->unlike(
        $body // '',
        qr/if \(ref\(\$data\) eq 'HASH' && exists \$data->\{status\}/,
        'fortniteStats_ctx no longer needs a defensive ref check at status access because data is already a HASH'
    );
};
