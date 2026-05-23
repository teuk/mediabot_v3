# t/cases/377_healthcheck_uptime_metric_syntax.t
use strict;
use warnings;
use File::Spec;

sub _slurp_377 {
    open my $fh, '<:encoding(UTF-8)', $_[0] or die $!;
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_377(File::Spec->catfile('.', 'mediabot.pl'));

    $assert->like($src, qr/mediabot_uptime_seconds/,
        'mediabot.pl updates mediabot_uptime_seconds');

    $assert->like($src, qr/eval\s*\{\s*my\s+\$up\s*=\s*time\(\)\s*-\s*\(\$mediabot->\{_start_time\}/s,
        'uptime gauge update is in its own eval block');

    $assert->unlike($src, qr/\[health_check\].*?# FF10: update uptime gauge/s,
        'FF10 uptime code is not embedded inside health_check log concatenation');

    $assert->like($src, qr/claude_sessions=\$hist_count karma_cooldowns=\$cd_count/,
        'health_check log still includes Claude and karma cooldown counts');
};
