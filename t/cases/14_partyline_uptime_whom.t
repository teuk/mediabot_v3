# t/cases/14_partyline_uptime_whom.t
# =============================================================================
# Static regression checks for Partyline .uptime and .whom display.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $partyline = _slurp(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));

    $assert->ok(
        $partyline =~ /elsif \(\$line =~ \/^\\\.uptime\$\/i\)/,
        'Partyline dispatches .uptime'
    );

    $assert->ok(
        $partyline =~ /sub _cmd_uptime/,
        'Partyline has _cmd_uptime'
    );

    $assert->ok(
        $partyline =~ /sub _format_duration/,
        'Partyline has _format_duration helper'
    );

    $assert->ok(
        $partyline =~ /\/proc\/uptime/,
        'Partyline .uptime reads server uptime from /proc/uptime'
    );

    $assert->ok(
        $partyline =~ /Bot\s+\s*:/ || $partyline =~ /Bot\s+.*_format_duration/,
        'Partyline .uptime reports bot uptime'
    );

    $assert->ok(
        $partyline =~ /\.uptime\s+- show bot and server uptime/,
        'Partyline help documents .uptime'
    );

    $assert->ok(
        $partyline =~ /Nick\/Host/,
        'Partyline .whom uses Nick/Host header'
    );

    $assert->ok(
        $partyline =~ /my \@rows;/,
        'Partyline .whom builds dynamic rows'
    );

    $assert->ok(
        $partyline =~ /\$nick_width = 80 if \$nick_width > 80;/,
        'Partyline .whom clamps dynamic nick width'
    );

    $assert->ok(
        $partyline !~ /Nick\s+Level\s+Socket\s+Console/,
        'Partyline .whom no longer uses fixed narrow header'
    );
};
