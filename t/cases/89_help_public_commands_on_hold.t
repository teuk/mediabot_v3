# t/cases/89_help_public_commands_on_hold.t
# =============================================================================
# Regression check for help <PUBLIC_COMMANDS command>.
#
# help <command> should delegate to showcmd when the command exists in
# PUBLIC_COMMANDS, even if it is currently on hold (active = 0).
#
# showcmd already displays:
#   Status : active
#   Status : on hold
#
# Therefore the help lookup must check existence, not executability.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_help_public_commands_on_hold {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_help_public_commands_on_hold {
    my ($src, $sub_name) = @_;

    my $start_re = qr/^sub\s+\Q$sub_name\E\s*\{/m;
    return undef unless $src =~ /$start_re/g;

    my $start = pos($src);
    my $depth = 1;
    my $pos   = $start;
    my $len   = length($src);

    while ($pos < $len) {
        my $char = substr($src, $pos, 1);

        if ($char eq '{') {
            $depth++;
        }
        elsif ($char eq '}') {
            $depth--;
            if ($depth == 0) {
                return substr($src, $start, $pos - $start);
            }
        }

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_help_public_commands_on_hold(
        File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm')
    );

    my $lookup = _extract_sub_body_help_public_commands_on_hold(
        $src,
        '_mbHelpPublicCommandExists'
    );

    my $help = _extract_sub_body_help_public_commands_on_hold(
        $src,
        'mbHelp_ctx'
    );

    $assert->ok(
        defined $lookup,
        '_mbHelpPublicCommandExists body found'
    );

    $assert->ok(
        defined $help,
        'mbHelp_ctx body found'
    );

    $assert->ok(
        $lookup =~ /SELECT 1 FROM PUBLIC_COMMANDS WHERE command = \? LIMIT 1/,
        'PUBLIC_COMMANDS help lookup checks command existence'
    );

    $assert->ok(
        $lookup !~ /AND\s+active\s*=\s*1/i,
        'PUBLIC_COMMANDS help lookup does not exclude on-hold commands'
    );

    $assert->ok(
        $help =~ /if \(_mbHelpPublicCommandExists\(\$self,\s*\$cmd\)\)/,
        'mbHelp_ctx uses PUBLIC_COMMANDS existence helper'
    );

    $assert->ok(
        $help =~ /return mbDbShowCommand_ctx\(\$ctx\)/,
        'mbHelp_ctx delegates PUBLIC_COMMANDS help to showcmd'
    );

    $assert->ok(
        $src =~ /my \$status\s*=\s*\$active \? 'active' : 'on hold'/,
        'showcmd already displays active/on-hold status'
    );
};
