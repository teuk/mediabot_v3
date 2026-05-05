# t/cases/102_weather_user_agent_configurable.t
# =============================================================================
# Regression checks for the wttr.in/weather HTTP User-Agent.
#
# The public code should not hard-code a private deployment URL in outbound HTTP
# headers. The weather User-Agent should use main.MAIN_PROG_URL when available
# and fall back to a neutral project URL.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_weather_user_agent {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_weather_user_agent {
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

    my $external = _slurp_weather_user_agent(
        File::Spec->catfile('.', 'Mediabot', 'External.pm')
    );

    my $sample = _slurp_weather_user_agent(
        File::Spec->catfile('.', 'mediabot.sample.conf')
    );

    my $weather = _extract_sub_body_weather_user_agent(
        $external,
        'displayWeather_ctx'
    );

    $assert->ok(
        defined $weather,
        'displayWeather_ctx body found'
    );

    $assert->like(
        $sample,
        qr/^MAIN_PROG_URL=/m,
        'sample config documents main.MAIN_PROG_URL'
    );

    $assert->like(
        $weather // '',
        qr/get\('main\.MAIN_PROG_URL'\)/,
        'weather User-Agent reads main.MAIN_PROG_URL'
    );

    $assert->like(
        $weather // '',
        qr/my\s+\$weather_agent\s*=\s*"mediabot_v3 weather\/1\.0 \(\+\$project_url\)"/,
        'weather User-Agent is built from project_url'
    );

    $assert->like(
        $weather // '',
        qr/agent\s*=>\s*\$weather_agent/,
        'weather HTTP client uses the computed User-Agent'
    );

    $assert->unlike(
        $weather // '',
        qr/mediabot_v3 weather\/1\.0 \(\+https:\/\/teuk\.org\)/,
        'weather User-Agent no longer hard-codes a private deployment URL'
    );
};
