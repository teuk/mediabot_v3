# t/cases/182_openai_fallback_model.t
# =============================================================================
# Regression checks for OpenAI/tellme fallback model support.
#
# A configured fallback model should be available for cases where the primary
# model is forbidden or unavailable, such as a GPT-5 model returning HTTP 403.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_182 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_182 {
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

    my $external = _slurp_182(File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm'));
    my $admin    = _slurp_182(File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm'));
    my $sample   = _slurp_182('mediabot.sample.conf');

    my $chatgpt_body = _extract_sub_body_182($external, 'chatGPT');

    $assert->ok(defined $chatgpt_body, 'chatGPT body found');

    $assert->like(
        $chatgpt_body // '',
        qr/openai\.FALLBACK_MODEL/,
        'chatGPT reads openai.FALLBACK_MODEL'
    );

    $assert->like(
        $chatgpt_body // '',
        qr/my \$build_payload = sub/,
        'chatGPT builds payload per model'
    );

    $assert->like(
        $chatgpt_body // '',
        qr/my \$send_request = sub/,
        'chatGPT sends requests through a retryable helper'
    );

    $assert->like(
        $chatgpt_body // '',
        qr/\$chatgpt_fallback_model ne ''/,
        'chatGPT checks fallback model is configured'
    );

    # mb418: le déclencheur de fallback utilise $primary_status et ajoute le
    # 429 rate-limit (hors insufficient_quota).
    $assert->like(
        $chatgpt_body // '',
        qr/\$primary_status == 400/,
        'chatGPT considers HTTP 400 fallback-eligible'
    );

    $assert->like(
        $chatgpt_body // '',
        qr/\$primary_status == 403/,
        'chatGPT considers HTTP 403 fallback-eligible'
    );

    $assert->like(
        $chatgpt_body // '',
        qr/\$primary_status == 404/,
        'chatGPT considers HTTP 404 fallback-eligible'
    );

    $assert->like(
        $chatgpt_body // '',
        qr/\$primary_status == 429 && !\$quota_exhausted/,
        'chatGPT considers transient HTTP 429 fallback-eligible (not quota)'
    );

    $assert->like(
        $chatgpt_body // '',
        qr/retrying with fallback model/,
        'chatGPT logs fallback retry'
    );

    $assert->like(
        $admin,
        qr/fallback_model => \{/,
        'openai admin command has fallback_model spec'
    );

    $assert->like(
        $admin,
        qr/openai\.FALLBACK_MODEL/,
        'openai admin command maps fallback_model to config key'
    );

    $assert->like(
        $admin,
        qr/fallback_model=\$fallback_model/,
        'openai status displays fallback_model'
    );

    $assert->like(
        $admin,
        qr/model fallback_model temperature/,
        'openai set/reset valid parameter list includes fallback_model'
    );

    $assert->like(
        $sample,
        qr/^FALLBACK_MODEL=/m,
        'sample config documents FALLBACK_MODEL'
    );

    $assert->like(
        $sample,
        qr/openai set fallback_model gpt-4o-mini/,
        'sample config documents setting fallback_model'
    );

    $assert->like(
        $sample,
        qr/openai reset fallback_model/,
        'sample config documents resetting fallback_model'
    );
};
