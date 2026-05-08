# t/cases/192_seen_persisted_respects_channel_scope.t
# =============================================================================
# Regression checks for mbSeen_ctx().
#
# seen <nick> #channel must keep both online and persisted USER_SEEN lookups
# scoped to that channel. Otherwise it can report an unrelated channel.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_192 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_192 {
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

    my $src = _slurp_192(
        File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm')
    );

    my $body = _extract_sub_body_192($src, 'mbSeen_ctx');

    $assert->ok(defined $body, 'mbSeen_ctx body found');

    $assert->like(
        $body // '',
        qr/WHERE nick = \? AND channel = \?/,
        'mbSeen_ctx scopes USER_SEEN lookup by channel when requested'
    );

    $assert->like(
        $body // '',
        qr/\@bind = \(\$targetNick, \$chan_for_part\);/,
        'mbSeen_ctx binds nick and channel for scoped USER_SEEN lookup'
    );

    $assert->like(
        $body // '',
        qr/\@bind = \(\$targetNick\);/,
        'mbSeen_ctx keeps global USER_SEEN lookup when no channel is requested'
    );

    $assert->like(
        $body // '',
        qr/my \(\$quit, \$part, \$chanlog\);/,
        'mbSeen_ctx has scoped CHANNEL_LOG fallback bucket'
    );

    $assert->like(
        $body // '',
        qr/event_type IN \('message', 'join', 'part', 'quit'\)/,
        'mbSeen_ctx channel fallback can use message/join/part/quit events'
    );

    $assert->like(
        $body // '',
        qr/\} elsif \(\$chanlog\) \{/,
        'mbSeen_ctx builds output from scoped CHANNEL_LOG fallback'
    );

    $assert->like(
        $body // '',
        qr/was last seen \$ago on \$chan_for_part/,
        'mbSeen_ctx scoped fallback reports the requested channel'
    );

    $assert->unlike(
        $body // '',
        qr/FROM USER_SEEN WHERE nick = \? LIMIT 1/,
        'mbSeen_ctx no longer uses the old unscoped USER_SEEN one-liner'
    );
};
