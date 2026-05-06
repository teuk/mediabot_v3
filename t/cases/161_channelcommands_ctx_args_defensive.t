# t/cases/161_channelcommands_ctx_args_defensive.t
# =============================================================================
# Regression checks for ChannelCommands context argument handling.
#
# Command wrappers should not assume $ctx->args is always an ARRAY reference.
# userTopicChannel_ctx() and setTMDBLangChannel_ctx() should follow the same
# defensive pattern as the rest of the command wrappers.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_channelcommands_ctx_args {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_channelcommands_ctx_args {
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

    my $src = _slurp_channelcommands_ctx_args(
        File::Spec->catfile('.', 'Mediabot', 'ChannelCommands.pm')
    );

    my $topic_body = _extract_sub_body_channelcommands_ctx_args($src, 'userTopicChannel_ctx');
    my $tmdb_body  = _extract_sub_body_channelcommands_ctx_args($src, 'setTMDBLangChannel_ctx');

    $assert->ok(
        defined $topic_body,
        'userTopicChannel_ctx body found'
    );

    $assert->ok(
        defined $tmdb_body,
        'setTMDBLangChannel_ctx body found'
    );

    $assert->like(
        $topic_body // '',
        qr/my \@args\s+= \(ref\(\$ctx->args\) eq 'ARRAY'\) \? \@\{ \$ctx->args \} : \(\);/,
        'userTopicChannel_ctx reads context args defensively'
    );

    $assert->like(
        $topic_body // '',
        qr/userTopicChannel\(\$ctx->bot, \$ctx->message, \$ctx->nick, \$ctx->channel, \@args\);/,
        'userTopicChannel_ctx forwards safe args'
    );

    $assert->unlike(
        $topic_body // '',
        qr/userTopicChannel\(\$ctx->bot, \$ctx->message, \$ctx->nick, \$ctx->channel, \@\{ \$ctx->args \}\);/,
        'userTopicChannel_ctx no longer blindly dereferences ctx args'
    );

    $assert->like(
        $tmdb_body // '',
        qr/my \@args\s+= \(ref\(\$ctx->args\) eq 'ARRAY'\) \? \@\{ \$ctx->args \} : \(\);/,
        'setTMDBLangChannel_ctx reads context args defensively'
    );

    $assert->unlike(
        $tmdb_body // '',
        qr/my \@args\s+= \@\{ \$ctx->args \};/,
        'setTMDBLangChannel_ctx no longer blindly dereferences ctx args'
    );

    $assert->like(
        $tmdb_body // '',
        qr/Syntax: tmdblangset \[#channel\] <lang>/,
        'setTMDBLangChannel_ctx still keeps its syntax message'
    );
};
