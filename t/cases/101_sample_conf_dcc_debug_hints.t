# t/cases/101_sample_conf_dcc_debug_hints.t
# =============================================================================
# Regression checks for DCC_DEBUG_HINTS sample config behavior.
#
# DCC_PUBLIC_IP and DCC_PORT_MIN/MAX are optional and may stay commented.
# DCC_DEBUG_HINTS is read directly by mediabot.pl as main.DCC_DEBUG_HINTS,
# so the sample should define its default explicitly.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_dcc_debug_hints {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _section_body_dcc_debug_hints {
    my ($src, $section) = @_;

    my ($body) = $src =~ /^\[\Q$section\E\]\s*\n(.*?)(?=^\[[^\]]+\]\s*$|\z)/ms;
    return $body;
}

return sub {
    my ($assert) = @_;

    my $sample = _slurp_dcc_debug_hints(
        File::Spec->catfile('.', 'mediabot.sample.conf')
    );

    my $main = _slurp_dcc_debug_hints(
        File::Spec->catfile('.', 'mediabot.pl')
    );

    my $main_section = _section_body_dcc_debug_hints($sample, 'main');

    $assert->ok(
        defined $main_section,
        'sample config has a [main] section'
    );

    $assert->like(
        $main_section // '',
        qr/^DCC_DEBUG_HINTS=0$/m,
        '[main] defines DCC_DEBUG_HINTS=0 explicitly'
    );

    $assert->unlike(
        $main_section // '',
        qr/^#DCC_DEBUG_HINTS=/m,
        '[main] does not leave DCC_DEBUG_HINTS commented'
    );

    $assert->like(
        $main,
        qr/get\('main\.DCC_DEBUG_HINTS'\)/,
        'mediabot.pl reads main.DCC_DEBUG_HINTS'
    );

    $assert->like(
        $main_section // '',
        qr/^#DCC_PUBLIC_IP=203\.0\.113\.10$/m,
        'DCC_PUBLIC_IP remains commented because it is optional/deployment-specific'
    );

    $assert->like(
        $main_section // '',
        qr/^#DCC_PORT_MIN=50000$/m,
        'DCC_PORT_MIN remains commented because it is optional'
    );

    $assert->like(
        $main_section // '',
        qr/^#DCC_PORT_MAX=50100$/m,
        'DCC_PORT_MAX remains commented because it is optional'
    );
};
