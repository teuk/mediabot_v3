# t/cases/212_fortnite_comment_cleanup_regression.t
# =============================================================================
# Regression checks for stale comments around getFortniteId().
#
# getFortniteId() used to be preceded by a copied YouTube duration comment.
# That was misleading during refactors. Keep the comment aligned with the
# actual Fortnite helper behavior.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_212 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_212(
        File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm')
    );

    $assert->unlike(
        $src,
        qr/Duration:\s+ISO8601\s+"PT#H#M#S"/,
        'stale YouTube duration comment is gone'
    );

    $assert->like(
        $src,
        qr/# Return the Fortnite account id stored for a Mediabot user nickname\.\n# This is used by fortniteStats_ctx\(\) before calling fortnite-api\.com\.\n\s*sub getFortniteId \{/,
        'getFortniteId has an accurate Fortnite-specific comment'
    );

    $assert->like(
        $src,
        qr/sub getFortniteId \{\n\s+my \(\$self,\s*\$sUser\) = \@_;/,
        'getFortniteId signature is unchanged'
    );

    $assert->like(
        $src,
        qr/SELECT fortniteid FROM USER WHERE nickname = \?/,
        'getFortniteId still fetches fortniteid by nickname'
    );

    $assert->like(
        $src,
        qr/my \$account_id = getFortniteId\(\$self,\s*\$target_name\);/,
        'fortniteStats_ctx still uses getFortniteId'
    );
};
