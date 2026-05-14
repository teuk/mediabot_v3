# t/cases/217_usercommands_karma_cap.t
# =============================================================================
# Verify processKarma caps at 3 karma changes per message (C2/fix).
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_217 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/; return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_217(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));

    # C2/fix must be present
    $assert->like($src, qr/karma_hits/,
        'processKarma has karma_hits cap variable');

    $assert->like($src, qr/last if.*karma_hits.*>.*3/,
        'processKarma exits loop after 3 karma changes');

    # Self-karma block
    $assert->like($src, qr/you can.t change your own karma/i,
        'processKarma blocks self-karma with message');
};
