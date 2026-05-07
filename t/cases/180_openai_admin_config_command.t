# t/cases/180_openai_admin_config_command.t
# =============================================================================
# Regression checks for the Owner-only openai admin command.
#
# The command should show, explain, set and reset safe tellme/OpenAI runtime
# parameters without exposing or accepting the API key from IRC.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_180 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_180 {
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

    my $admin  = _slurp_180(File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm'));
    my $main   = _slurp_180(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
    my $sample = _slurp_180('mediabot.sample.conf');

    my $body = _extract_sub_body_180($admin, 'openai_ctx');

    $assert->ok(defined $body, 'openai_ctx body found');

    $assert->like($admin, qr/openai_ctx/, 'openai_ctx is present in AdminCommands');
    $assert->like($body // '', qr/return unless \$ctx->require_level\('Owner'\);/, 'openai_ctx is Owner-only');
    $assert->like($admin, qr/sub _openai_param_spec/, 'OpenAI parameter spec helper exists');

    for my $param (qw(api_url model temperature max_tokens max_privmsg wrap_bytes sleep_us)) {
        $assert->like($admin, qr/\Q$param\E/, "openai command knows parameter $param");
    }

    for my $verb (qw(status config help defaults explain set reset)) {
        $assert->like($body // '', qr/\Q$verb\E/, "openai_ctx supports $verb");
    }

    $assert->like(
        $body // '',
        qr/\$self->\{conf\}->set\(\$spec->\{key\}, \$clean_or_error\);/,
        'openai set persists validated values'
    );

    $assert->like(
        $body // '',
        qr/\$self->\{conf\}->set\(\$spec->\{key\}, \$spec->\{default\}\);/,
        'openai reset persists default values'
    );

    $assert->like(
        $body // '',
        qr/\$self->\{conf\}->save\(\);/,
        'openai set/reset saves the config'
    );

    $assert->like(
        $admin,
        qr/API_KEY is intentionally not changeable from IRC/,
        'openai command documents that API_KEY is not editable from IRC'
    );

    $assert->unlike(
        $body // '',
        qr/API_KEY.*set/s,
        'openai set does not offer API_KEY as a settable parameter'
    );

    $assert->like(
        $main,
        qr/openai\s+=> sub \{ openai_ctx\(\$ctx\) \}/,
        'Mediabot dispatch exposes openai command'
    );

    $assert->like(
        $main,
        qr/openai\|openai help\|owner\|Show and change safe OpenAI\/tellme runtime settings\./,
        'help table documents openai command'
    );

    $assert->like($sample, qr/openai set model gpt-4o-mini/, 'sample config documents openai set model');
    $assert->like($sample, qr/openai set temperature 0\.6/, 'sample config documents openai set temperature');
    $assert->like($sample, qr/API_KEY is intentionally not changeable from IRC/, 'sample config documents API_KEY security policy');
    $assert->like($sample, qr/chanset #channel \+chatGPT/, 'sample config documents chatGPT channel enablement');
};
