# t/cases/98_sample_conf_retention_keys.t
# =============================================================================
# Regression checks for retention configuration keys.
#
# Mediabot.pm reads:
#   main.CHANNEL_LOG_RETENTION_DAYS
#   main.USER_SEEN_RETENTION_DAYS
#
# The root sample config must document those keys explicitly so admins can
# tune cleanup behavior instead of relying on hidden defaults.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_retention_keys {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_retention_keys {
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

    my $sample = _slurp_retention_keys(
        File::Spec->catfile('.', 'mediabot.sample.conf')
    );

    my $core = _slurp_retention_keys(
        File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm')
    );

    $assert->like(
        $sample,
        qr/^\[main\]$/m,
        'sample config has a [main] section'
    );

    $assert->like(
        $sample,
        qr/^CHANNEL_LOG_RETENTION_DAYS=90$/m,
        'sample config documents CHANNEL_LOG_RETENTION_DAYS=90'
    );

    $assert->like(
        $sample,
        qr/^USER_SEEN_RETENTION_DAYS=180$/m,
        'sample config documents USER_SEEN_RETENTION_DAYS=180'
    );

    $assert->like(
        $sample,
        qr/Retention period for channel log maintenance/,
        'sample config explains channel log retention'
    );

    $assert->like(
        $sample,
        qr/Retention period for USER seen\/activity cleanup/,
        'sample config explains user seen retention'
    );

    $assert->like(
        $core,
        qr/get\('main\.CHANNEL_LOG_RETENTION_DAYS'\)/,
        'Mediabot.pm reads main.CHANNEL_LOG_RETENTION_DAYS'
    );

    $assert->like(
        $core,
        qr/get\('main\.USER_SEEN_RETENTION_DAYS'\)/,
        'Mediabot.pm reads main.USER_SEEN_RETENTION_DAYS'
    );

    $assert->like(
        $core,
        qr/CHANNEL_LOG_RETENTION_DAYS'\) \} \/\/ 90/,
        'channel log retention fallback remains 90 days'
    );

    $assert->like(
        $core,
        qr/USER_SEEN_RETENTION_DAYS'\) \} \/\/ 180/,
        'user seen retention fallback remains 180 days'
    );
};
