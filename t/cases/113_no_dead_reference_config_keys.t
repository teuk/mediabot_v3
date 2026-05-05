# t/cases/113_no_dead_reference_config_keys.t
# =============================================================================
# Regression checks for dead reference configuration keys.
#
# These keys used to appear in sample/generated configs, but are not read by
# current runtime code. Keeping them active in reference configs is misleading.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_no_dead_reference_keys {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my %files = (
        sample            => File::Spec->catfile('.', 'mediabot.sample.conf'),
        live_template     => File::Spec->catfile('.', 't', 'live', 'test.conf.tpl'),
        configure         => File::Spec->catfile('.', 'configure'),
        install_configure => File::Spec->catfile('.', 'install', 'configure.pl'),
    );

    my @dead_keys = qw(
        CONN_NICK_ALTERNATE
        UNET_CSERVICE_HOSTMASK
        MAIN_PROG_NAME_LOWER
        MAIN_PROG_TZ
        MAIN_SQL_FLOOD_PROTECT_COUNT
        MAIN_SQL_FLOOD_PROTECT_DURATION
    );

    for my $name (sort keys %files) {
        my $src = _slurp_no_dead_reference_keys($files{$name});

        for my $key (@dead_keys) {
            $assert->unlike(
                $src,
                qr/\Q$key\E/,
                "$name no longer contains dead reference key $key"
            );
        }
    }

    my $runtime = _slurp_no_dead_reference_keys(
        File::Spec->catfile('.', 'mediabot.pl')
    );

    for my $module (qw(
        AdminCommands Auth Channel ChannelBan ChannelCommands Command Conf Context
        DB DBCommands DCC External Hailo Helpers Log LoginCommands Mediabot
        Metrics Partyline Quotes Scheduler User UserCommands
    )) {
        my $path = File::Spec->catfile('.', 'Mediabot', "$module.pm");
        next unless -f $path;
        $runtime .= "\n" . _slurp_no_dead_reference_keys($path);
    }

    for my $key (@dead_keys) {
        $assert->unlike(
            $runtime,
            qr/get\('[^']*\.\Q$key\E'\)/,
            "runtime does not read $key through configuration"
        );
    }
};
