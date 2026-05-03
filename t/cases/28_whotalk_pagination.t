# t/cases/28_whotalk_pagination.t
# =============================================================================
# Static regression checks for whotalk paginated output.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_whotalk_pagination {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_whotalk_pagination(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));

    $assert->ok(
        $src =~ /sub whoTalk_ctx/,
        'whoTalk_ctx exists'
    );

    $assert->ok(
        $src =~ /Top talkers last hour on \$target: \$count result\(s\), showing max 20/,
        'whotalk has paginated summary line'
    );

    $assert->ok(
        $src =~ /details sent by notice to \$nick/,
        'whotalk avoids multi-line channel flood'
    );

    $assert->ok(
        $src =~ /my \$per_line = 5;/,
        'whotalk paginates at 5 talkers per line'
    );

    $assert->ok(
        $src =~ /whotalk\[%02d\]/,
        'whotalk detail lines are numbered'
    );

    $assert->ok(
        $src =~ /botNotice\(\$self, \$nick, \$line\);/,
        'whotalk sends paginated details by notice'
    );

    $assert->ok(
        $src =~ /please slow down a bit/,
        'whotalk keeps gentle flood warning'
    );

    $assert->ok(
        $src !~ /Build one-line summary with truncation/,
        'whotalk old one-line truncation comment is gone'
    );

    $assert->ok(
        $src !~ /my \$prefix\s+=\s+"Top talkers last hour/,
        'whotalk no longer builds one huge prefix line'
    );
};
