# t/cases/186_openai_system_prompt_config.t
# =============================================================================
# Regression checks for configurable OpenAI/tellme system prompt.
#
# The system prompt should be configurable from [openai], manageable through the
# Owner-only openai admin command, and not fully dumped by status.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_186 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_186 {
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

    my $external = _slurp_186(File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm'));
    my $admin    = _slurp_186(File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm'));
    my $sample   = _slurp_186('mediabot.sample.conf');

    my $chatgpt_body = _extract_sub_body_186($external, 'chatGPT');
    my $validate_body = _extract_sub_body_186($admin, '_openai_validate_value');

    $assert->ok(defined $chatgpt_body, 'chatGPT body found');
    $assert->ok(defined $validate_body, '_openai_validate_value body found');

    $assert->like(
        $external,
        qr/CHATGPT_SYSTEM_PROMPT/,
        'External/Claude.pm defines CHATGPT_SYSTEM_PROMPT default'
    );

    $assert->like(
        $chatgpt_body // '',
        qr/openai\.SYSTEM_PROMPT/,
        'chatGPT reads openai.SYSTEM_PROMPT'
    );

    $assert->like(
        $chatgpt_body // '',
        qr/\$chatgpt_system_prompt =~ s\/\\r\|\\n\/ \//,
        'chatGPT removes newlines from configured system prompt'
    );

    $assert->like(
        $chatgpt_body // '',
        qr/\$chatgpt_system_prompt = substr\(\$chatgpt_system_prompt, 0, 800\);/,
        'chatGPT caps system prompt length'
    );

    $assert->like(
        $chatgpt_body // '',
        qr/content => \$chatgpt_system_prompt/,
        'chatGPT payload uses configured system prompt'
    );

    $assert->like(
        $admin,
        qr/system_prompt => \{/,
        'OpenAI admin has system_prompt parameter spec'
    );

    $assert->like(
        $admin,
        qr/openai\.SYSTEM_PROMPT/,
        'system_prompt maps to openai.SYSTEM_PROMPT'
    );

    $assert->like(
        $validate_body // '',
        qr/if \(\$spec->\{type\} eq 'text'\)/,
        'OpenAI admin validates text parameters'
    );

    $assert->like(
        $admin,
        qr/system_prompt_len/,
        'OpenAI status reports system_prompt_len'
    );

    $assert->like(
        $admin,
        qr/system_prompt temperature/,
        'OpenAI valid parameter list includes system_prompt'
    );

    $assert->like(
        $sample,
        qr/^SYSTEM_PROMPT=/m,
        'sample config documents SYSTEM_PROMPT'
    );

    $assert->like(
        $sample,
        qr/openai set system_prompt/,
        'sample config documents setting system_prompt'
    );

    $assert->like(
        $sample,
        qr/status command only shows system_prompt_len/,
        'sample config documents prompt privacy behavior'
    );
};
