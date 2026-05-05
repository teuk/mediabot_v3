# t/cases/116_readme_root_sample_path.t
# =============================================================================
# Regression checks for README sample config paths.
#
# The official sample config lives at the repository root:
#   mediabot.sample.conf
#
# The README must not tell users to copy conf/mediabot.sample.conf.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_readme_root_sample_path {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $readme = _slurp_readme_root_sample_path(
        File::Spec->catfile('.', 'README.md')
    );

    $assert->ok(
        -f File::Spec->catfile('.', 'mediabot.sample.conf'),
        'root mediabot.sample.conf exists'
    );

    $assert->unlike(
        $readme,
        qr/conf\/mediabot\.sample\.conf/,
        'README does not reference obsolete conf/mediabot.sample.conf path'
    );

    $assert->like(
        $readme,
        qr/^cp mediabot\.sample\.conf mediabot\.conf$/m,
        'README copies root sample config to mediabot.conf'
    );

    $assert->like(
        $readme,
        qr/^chmod 600 mediabot\.conf$/m,
        'README chmods root mediabot.conf'
    );

    $assert->like(
        $readme,
        qr/^vi mediabot\.conf$/m,
        'README edits root mediabot.conf'
    );

    $assert->like(
        $readme,
        qr/Useful sample files to keep in the repository:/,
        'README keeps the sample files section'
    );

    $assert->like(
        $readme,
        qr/^mediabot\.sample\.conf$/m,
        'README lists root mediabot.sample.conf as useful sample file'
    );
};
