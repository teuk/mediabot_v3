# t/cases/168_chanset_owner_admin_permission.t
# =============================================================================
# Regression checks for ChannelCommands::channelSet_ctx().
#
# channelSet_ctx() should call $user->has_level('Administrator'), not
# $user->has_level($self, 'Administrator'). Passing the bot object as the first
# argument makes Owner/Admin users fail the global permission check.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_chanset_permission {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_chanset_permission {
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

    my $src = _slurp_chanset_permission(
        File::Spec->catfile('.', 'Mediabot', 'ChannelCommands.pm')
    );

    my $body = _extract_sub_body_chanset_permission($src, 'channelSet_ctx');

    $assert->ok(
        defined $body,
        'channelSet_ctx body found'
    );

    $assert->like(
        $body // '',
        qr/my \$is_admin = eval \{ \$user->has_level\('Administrator'\) \? 1 : 0 \} \|\| 0;/,
        'channelSet_ctx checks global Administrator+ level correctly'
    );

    $assert->unlike(
        $body // '',
        qr/has_level\(\$self, 'Administrator'\)/,
        'channelSet_ctx no longer passes the bot object to has_level'
    );

    $assert->like(
        $body // '',
        qr/my \$is_chan\s+= checkUserChannelLevel\(\$self, \$ctx->message, \$target_channel, \$user->id, 450\) \? 1 : 0;/,
        'channelSet_ctx still allows per-channel level >= 450'
    );

    $assert->like(
        $body // '',
        qr/unless \(\$is_admin \|\| \$is_chan\)/,
        'channelSet_ctx still permits global admin or channel-level access'
    );

    $assert->like(
        $body // '',
        qr/Your level does not allow you to use this command\./,
        'channelSet_ctx still denies users without either permission'
    );
};
