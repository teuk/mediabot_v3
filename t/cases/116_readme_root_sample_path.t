# t/cases/116_readme_root_sample_path.t
# =============================================================================
# Regression checks for the supported fresh-install configuration workflow.
#
# ./configure creates mediabot.conf. mediabot.sample.conf is a root-level
# reference file, not a file that README should instruct users to copy blindly.
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
    $assert->ok(-x File::Spec->catfile('.', 'configure'), './configure exists and is executable');
    $assert->unlike(
        $readme,
        qr/conf\/mediabot\.sample\.conf/,
        'README does not reference obsolete conf/mediabot.sample.conf path'
    );
    $assert->unlike(
        $readme,
        qr/^cp\s+mediabot\.sample\.conf\s+mediabot\.conf$/m,
        'README does not recommend blindly copying the sample config'
    );
    $assert->like(
        $readme,
        qr/^### 4\. Run `\.\/configure`$/m,
        'README presents ./configure as the installation step'
    );
    $assert->like(
        $readme,
        qr/^\.\/configure$/m,
        'README documents the configure command'
    );
    $assert->like(
        $readme,
        qr/`mediabot\.sample\.conf` is a reference file\./,
        'README describes mediabot.sample.conf as a reference file'
    );
    $assert->like($readme, qr/^chmod 600 mediabot\.conf$/m, 'README secures generated mediabot.conf');
    $assert->like($readme, qr/^vi mediabot\.conf$/m, 'README reviews generated mediabot.conf');
    $assert->like($readme, qr/Never commit the real `mediabot\.conf`\./, 'README warns against committing runtime config');
};
