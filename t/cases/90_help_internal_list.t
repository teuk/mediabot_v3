# t/cases/90_help_internal_list.t
# =============================================================================
# Regression checks for:
#   help internal
#   help internals
#   help commands
#
# These should list internal bot commands, not query PUBLIC_COMMANDS.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_help_internal_list {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_help_internal_list {
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

    my $src = _slurp_help_internal_list(
        File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm')
    );

    my $list = _extract_sub_body_help_internal_list(
        $src,
        '_mbHelpSendInternalList'
    );

    my $help = _extract_sub_body_help_internal_list(
        $src,
        'mbHelp_ctx'
    );

    $assert->ok(
        defined $list,
        '_mbHelpSendInternalList exists'
    );

    $assert->ok(
        defined $help,
        'mbHelp_ctx exists'
    );

    $assert->ok(
        index($help, '$first =~ /^(?:internal|internals|commands)$/i') >= 0,
        'help recognizes internal/internals/commands'
    );

    $assert->ok(
        $help =~ /return _mbHelpSendInternalList\(\$ctx\)/,
        'help internal delegates to internal list helper'
    );

    $assert->ok(
        $list =~ /Internal commands help:/,
        'internal list has a clear title'
    );

    $assert->ok(
        $list =~ /Public\/private:/,
        'internal list separates public/private commands'
    );

    $assert->ok(
        $list =~ /Privileged\/admin:/,
        'internal list separates privileged/admin commands'
    );

    $assert->ok(
        $list =~ /Use: help <command> for syntax and explanation/,
        'internal list points to detailed help'
    );

    $assert->ok(
        $list =~ /Dynamic PUBLIC_COMMANDS/,
        'internal list explicitly distinguishes dynamic PUBLIC_COMMANDS'
    );
};
