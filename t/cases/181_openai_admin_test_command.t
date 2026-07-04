# t/cases/181_openai_admin_test_command.t
# =============================================================================
# Regression checks for the Owner-only "openai test" command.
#
# It should test the configured API key/model/endpoint without exposing the key,
# and report HTTP status, latency and a short answer/error in notices.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_181 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_181 {
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

    my $admin  = _slurp_181(File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm'));
    my $sample = _slurp_181('mediabot.sample.conf');

    my $test_body   = _extract_sub_body_181($admin, '_openai_run_test');
    my $openai_body = _extract_sub_body_181($admin, 'openai_ctx');

    $assert->ok(defined $test_body, '_openai_run_test body found');
    $assert->ok(defined $openai_body, 'openai_ctx body found');

    $assert->like($admin, qr/use HTTP::Tiny;/, 'AdminCommands imports HTTP::Tiny');
    $assert->like($admin, qr/use JSON qw\(encode_json decode_json\);/, 'AdminCommands imports JSON helpers');
    $assert->like($admin, qr/use Time::HiRes qw\(time\);/, 'AdminCommands imports high resolution time');

    $assert->like(
        $test_body // '',
        qr/openai\.API_KEY/,
        'openai test reads API key internally'
    );

    $assert->like(
        $test_body // '',
        qr/OpenAI test: API key is missing\./,
        'openai test reports missing key safely'
    );

    $assert->like(
        $test_body // '',
        qr/my \$api_url\s+= _openai_effective_value\(\$self, 'api_url'\);/,
        'openai test uses configured endpoint'
    );

    $assert->like(
        $test_body // '',
        qr/my \$model\s+= _openai_effective_value\(\$self, 'model'\);/,
        'openai test uses configured model'
    );

    $assert->like(
        $test_body // '',
        qr/HTTP \$status \$reason in \$\{elapsed_ms\}ms/,
        'openai test reports HTTP status and latency'
    );

    $assert->like(
        $test_body // '',
        qr/OpenAI test: provider_message=\$err_msg/,
        'openai test reports provider error message safely'
    );

    $assert->like(
        $test_body // '',
        qr/OpenAI test: answer=\$answer/,
        'openai test reports short answer'
    );

    $assert->unlike(
        $test_body // '',
        qr/botNotice\([^;]*\$api_key/s,
        'openai test never prints the API key'
    );

    $assert->like(
        $openai_body // '',
        qr/if \(\$subcmd eq 'test' \|\| \$subcmd eq 'ping' \|\| \$subcmd eq 'diagnose'\)/,
        'openai_ctx supports test, ping and diagnose aliases'
    );

    $assert->like(
        $openai_body // '',
        qr/_openai_run_test\(\$self, \$nick, \@args\);/,
        'openai_ctx dispatches to _openai_run_test'
    );

    $assert->like(
        $admin,
        qr/openai test\|diagnose \[prompt\]/,
        'openai help documents test and diagnose commands'
    );

    $assert->like(
        $sample,
        qr/openai test Reply with exactly OK/,
        'sample config documents openai test with custom prompt'
    );
};
