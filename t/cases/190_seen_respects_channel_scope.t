# t/cases/190_seen_respects_channel_scope.t
# =============================================================================
# Regression checks for mbSeen_ctx().
#
# seen <nick> [#channel] should parse the optional channel before checking
# whether a nick is currently online. If a channel is provided, the online
# shortcut must be scoped to that channel.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_190 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_190 {
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

    my $src = _slurp_190(
        File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm')
    );

    my $body = _extract_sub_body_190($src, 'mbSeen_ctx');

    $assert->ok(defined $body, 'mbSeen_ctx body found');

    $assert->like(
        $body // '',
        qr/my \$target_input = shift \@args;/,
        'mbSeen_ctx keeps original target input before normalization'
    );

    $assert->like(
        $body // '',
        qr/my \$targetNick = lc\(\$target_input\);/,
        'mbSeen_ctx still normalizes lookup key'
    );

    $assert->like(
        $body // '',
        qr/my \$chan_for_part;/,
        'mbSeen_ctx parses channel before online lookup'
    );

    $assert->like(
        $body // '',
        qr/next if defined\(\$chan_for_part\) && lc\(\$chan\) ne lc\(\$chan_for_part\);/,
        'mbSeen_ctx scopes online check to requested channel'
    );

    $assert->like(
        $body // '',
        qr/my \(\$online_nick\) = grep \{ lc\(\$_\) eq \$targetNick \} \@nicks;/,
        'mbSeen_ctx captures actual online nick casing'
    );

    $assert->like(
        $body // '',
        qr/\$online_nick is currently online on \$chan/,
        'mbSeen_ctx reports actual online nick'
    );

    $assert->unlike(
        $body // '',
        qr/my \$targetNick = lc\(shift \@args\);/,
        'mbSeen_ctx no longer checks online state before parsing channel argument'
    );

    $assert->unlike(
        $body // '',
        qr/\$targetNick is currently online on \$chan/,
        'mbSeen_ctx no longer reports lower-case target nick for online shortcut'
    );
};
