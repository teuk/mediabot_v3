# t/cases/97_sample_conf_dcc_single_block.t
# =============================================================================
# Regression checks for DCC/Partyline sample configuration.
#
# DCC options should be documented once in mediabot.sample.conf, under [main].
# A duplicate free-floating block after API sections is confusing because an INI
# parser would still associate uncommented keys with the previous section.
#
# Detailed compatibility aliases stay documented in docs/PARTYLINE_DCC.md.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_dcc_sample_block {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _section_body_dcc_sample_block {
    my ($src, $section) = @_;

    my ($body) = $src =~ /^\[\Q$section\E\]\s*\n(.*?)(?=^\[[^\]]+\]\s*$|\z)/ms;
    return $body;
}

return sub {
    my ($assert) = @_;

    my $sample = _slurp_dcc_sample_block(
        File::Spec->catfile('.', 'mediabot.sample.conf')
    );

    my $partyline = _slurp_dcc_sample_block(
        File::Spec->catfile('.', 'Mediabot', 'Partyline.pm')
    );

    my $doc = _slurp_dcc_sample_block(
        File::Spec->catfile('.', 'docs', 'PARTYLINE_DCC.md')
    );

    my $main = _section_body_dcc_sample_block($sample, 'main');

    $assert->ok(
        defined $main,
        'sample config has a [main] section'
    );

    $assert->like(
        $main // '',
        qr/#DCC_PUBLIC_IP=203\.0\.113\.10/,
        '[main] documents DCC_PUBLIC_IP'
    );

    $assert->like(
        $main // '',
        qr/^DCC_DEBUG_HINTS=0/m,
        '[main] defines DCC_DEBUG_HINTS explicitly'
    );

    $assert->like(
        $main // '',
        qr/#DCC_PORT_MIN=50000/,
        '[main] documents DCC_PORT_MIN'
    );

    $assert->like(
        $main // '',
        qr/#DCC_PORT_MAX=50100/,
        '[main] documents DCC_PORT_MAX'
    );

    my $dcc_public_ip_count = () = $sample =~ /^#DCC_PUBLIC_IP=/mg;
    my $dcc_port_min_count  = () = $sample =~ /^#DCC_PORT_MIN=/mg;
    my $dcc_port_max_count  = () = $sample =~ /^#DCC_PORT_MAX=/mg;

    $assert->is(
        $dcc_public_ip_count,
        1,
        'sample config documents DCC_PUBLIC_IP only once'
    );

    $assert->is(
        $dcc_port_min_count,
        1,
        'sample config documents DCC_PORT_MIN only once'
    );

    $assert->is(
        $dcc_port_max_count,
        1,
        'sample config documents DCC_PORT_MAX only once'
    );

    $assert->unlike(
        $sample,
        qr/Partyline \/ DCC CHAT/,
        'sample config has no duplicate trailing Partyline/DCC block'
    );

    $assert->unlike(
        $sample,
        qr/PARTYLINE_DCC_PUBLIC_IP/,
        'sample config does not include historical DCC alias examples'
    );

    $assert->like(
        $partyline,
        qr/main\.DCC_PUBLIC_IP/,
        'Partyline.pm accepts main.DCC_PUBLIC_IP'
    );

    $assert->like(
        $partyline,
        qr/main\.DCC_PORT_MIN/,
        'Partyline.pm accepts main.DCC_PORT_MIN'
    );

    $assert->like(
        $doc,
        qr/PARTYLINE_DCC_PUBLIC_IP/,
        'detailed DCC documentation still mentions historical alias names'
    );
};
