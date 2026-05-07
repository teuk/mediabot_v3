# t/cases/183_openai_admin_test_uses_fallback.t
# =============================================================================
# Regression checks for "openai test" fallback behavior.
#
# The admin test command should follow the same model fallback logic as tellme:
# retry FALLBACK_MODEL when the primary model is forbidden or unavailable.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_183 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_183 {
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

    my $admin  = _slurp_183(File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm'));
    my $sample = _slurp_183('mediabot.sample.conf');

    my $body = _extract_sub_body_183($admin, '_openai_run_test');

    $assert->ok(defined $body, '_openai_run_test body found');

    $assert->like(
        $body // '',
        qr/my \$fallback_model = _openai_effective_value\(\$self, 'fallback_model'\);/,
        'openai test reads fallback_model'
    );

    $assert->like(
        $body // '',
        qr/my \$build_payload = sub/,
        'openai test builds payload per selected model'
    );

    $assert->like(
        $body // '',
        qr/my \$send_test = sub/,
        'openai test sends requests through retryable helper'
    );

    $assert->like(
        $body // '',
        qr/\$fallback_model ne ''/,
        'openai test only retries when fallback_model is configured'
    );

    $assert->like(
        $body // '',
        qr/\(\(\$res->\{status\} \/\/ 0\) == 400/,
        'openai test considers HTTP 400 fallback-eligible'
    );

    $assert->like(
        $body // '',
        qr/\(\$res->\{status\} \/\/ 0\) == 403/,
        'openai test considers HTTP 403 fallback-eligible'
    );

    $assert->like(
        $body // '',
        qr/\(\$res->\{status\} \/\/ 0\) == 404/,
        'openai test considers HTTP 404 fallback-eligible'
    );

    $assert->like(
        $body // '',
        qr/trying fallback \$fallback_model/,
        'openai test reports fallback retry'
    );

    $assert->like(
        $body // '',
        qr/\$fallback_tried = 1;/,
        'openai test tracks fallback usage'
    );

    $assert->like(
        $body // '',
        qr/OpenAI test: fallback used:/,
        'openai test reports whether fallback was used'
    );

    $assert->unlike(
        $body // '',
        qr/botNotice\([^;]*\$api_key/s,
        'openai test still never prints API key'
    );

    $assert->like(
        $sample,
        qr/openai test also tries FALLBACK_MODEL/,
        'sample config documents openai test fallback behavior'
    );
};
