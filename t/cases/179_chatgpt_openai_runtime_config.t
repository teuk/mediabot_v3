# t/cases/179_chatgpt_openai_runtime_config.t
# =============================================================================
# Regression checks for tellme/chatGPT runtime configuration.
#
# chatGPT() should keep safe defaults but allow the OpenAI model, temperature,
# max tokens, IRC splitting, throttling and endpoint URL to be configured from
# the [openai] section.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_179 {
    my ($path) = @_;

    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_179 {
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

    my $src = _slurp_179(
        File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm')
    );

    my $sample = _slurp_179('mediabot.sample.conf');
    my $client = _slurp_179(File::Spec->catfile('.', 'Mediabot', 'AI', 'Client.pm'));

    my $chatgpt_body = _extract_sub_body_179($src, 'chatGPT');
    my $accept_body  = _extract_sub_body_179($src, '_chatgpt_deliver_answer');
    my $wrap_body    = _extract_sub_body_179($src, '_chatgpt_wrap');

    $assert->ok(defined $chatgpt_body, 'chatGPT body found');
    $assert->ok(defined $accept_body, '_chatgpt_deliver_answer body found');
    $assert->ok(defined $wrap_body, '_chatgpt_wrap body found');

    for my $helper (qw(_chatgpt_conf_int _chatgpt_conf_float _chatgpt_conf_string)) {
        $assert->like(
            $src,
            qr/sub \Q$helper\E/,
            "$helper helper exists"
        );
    }

    for my $key (qw(API_URL MODEL TEMPERATURE MAX_TOKENS MAX_PRIVMSG WRAP_BYTES SLEEP_US)) {
        $assert->like(
            $sample,
            qr/^$key=/m,
            "sample [openai] documents $key"
        );
    }

    $assert->like(
        $chatgpt_body // '',
        qr/my \$chatgpt_model\s+= _chatgpt_conf_string\(\$self, 'openai\.MODEL',\s+CHATGPT_MODEL\);/,
        'chatGPT reads openai.MODEL from config'
    );

    $assert->like(
        $chatgpt_body // '',
        qr/my \$chatgpt_temperature\s+= _chatgpt_conf_float\(\s*\$self, 'openai\.TEMPERATURE',\s+CHATGPT_TEMPERATURE,\s+0, 2\);/,
        'chatGPT reads guarded openai.TEMPERATURE from config'
    );

    $assert->like(
        $chatgpt_body // '',
        qr/my \$chatgpt_max_tokens\s+= _chatgpt_conf_int\(\s*\$self, 'openai\.MAX_TOKENS',\s+CHATGPT_MAX_TOKENS,\s+1, 4000\);/,
        'chatGPT reads guarded openai.MAX_TOKENS from config'
    );

    $assert->like(
        $chatgpt_body // '',
        qr/Mediabot::AI::Client->new\(/,
        'chatGPT delegates provider execution to the common AI client'
    );

    $assert->like(
        $chatgpt_body // '',
        qr/provider\s+=>\s+'openai'/,
        'tellme remains an explicit strict OpenAI request'
    );

    $assert->like(
        $client,
        qr/_conf_string\('openai\.MODEL'/,
        'common client resolves the configured OpenAI primary model'
    );

    $assert->like(
        $client,
        qr/Mediabot::AI::Provider::OpenAI::build_payload\(\$adapted\)/,
        'common client delegates payload serialization to OpenAI provider'
    );

    $assert->like(
        $chatgpt_body // '',
        qr/my \$chatgpt_fallback_model = _chatgpt_conf_string\(\$self, 'openai\.FALLBACK_MODEL', ''\);/,
        'chatGPT reads optional openai.FALLBACK_MODEL from config'
    );

    $assert->like(
        $chatgpt_body // '',
        qr/temperature\s+=>\s+\$chatgpt_temperature,/,
        'chatGPT passes configured temperature into provider-neutral request'
    );

    $assert->like(
        $chatgpt_body // '',
        qr/max_output_tokens\s+=>\s+\$chatgpt_max_tokens,/,
        'chatGPT maps configured max tokens into provider-neutral request'
    );

    $assert->like(
        $accept_body // '',
        qr/_chatgpt_wrap\(\$answer, \$state->\{wrap_bytes\}\)/,
        'parent acceptance uses configured wrap bytes'
    );

    $assert->like(
        $accept_body // '',
        qr/_queue_irc_chunks\(\s*\$self,\s*\$state->\{chan\},\s*\\\@out_chunks,\s*\$state->\{sleep_us\}/s,
        'parent acceptance passes configured pacing delay to the IRC queue'
    );

    $assert->like(
        $wrap_body // '',
        qr/my \(\$txt, \$wrap_bytes\) = \@_;/,
        '_chatgpt_wrap accepts runtime wrap limit'
    );

    $assert->unlike(
        $chatgpt_body // '',
        qr/model\s+=> CHATGPT_MODEL,/,
        'chatGPT no longer hardcodes CHATGPT_MODEL directly in payload'
    );

    $assert->unlike(
        $chatgpt_body // '',
        qr/usleep\(CHATGPT_SLEEP_US\);/,
        'chatGPT no longer hardcodes sleep delay at send time'
    );
};
