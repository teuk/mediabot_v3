# t/cases/121_mediabot_usage_spacing.t
# =============================================================================
# Regression checks for mediabot.pl usage output.
#
# The usage string should be copy/paste readable:
#   mediabot.pl --conf=<config_file>
#
# not:
#   mediabot.pl--conf=<config_file>
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_mediabot_usage_spacing {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_mediabot_usage_spacing(
        File::Spec->catfile('.', 'mediabot.pl')
    );

    $assert->like(
        $src,
        qr/log_error\("Usage: "\s*\.\s*basename\(\$0\)\s*\.\s*" --conf=<config_file>/,
        'usage string contains a space before --conf'
    );

    $assert->unlike(
        $src,
        qr/basename\(\$0\)\s*\.\s*"--conf=<config_file>/,
        'usage string does not glue script name and --conf together'
    );
};
