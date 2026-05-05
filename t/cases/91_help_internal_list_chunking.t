# t/cases/91_help_internal_list_chunking.t
# =============================================================================
# Regression checks for help internal list chunking.
#
# The internal command list is long enough that one NOTICE can exceed safe IRC
# line lengths. The list must therefore be split into several notices.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_help_internal_list_chunking {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_help_internal_list_chunking {
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

    my $src = _slurp_help_internal_list_chunking(
        File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm')
    );

    my $chunker = _extract_sub_body_help_internal_list_chunking(
        $src,
        '_mbHelpSendChunkedList'
    );

    my $list = _extract_sub_body_help_internal_list_chunking(
        $src,
        '_mbHelpSendInternalList'
    );

    $assert->ok(
        defined $chunker,
        '_mbHelpSendChunkedList exists'
    );

    $assert->ok(
        defined $list,
        '_mbHelpSendInternalList exists'
    );

    $assert->ok(
        $chunker =~ /my\s+\$max_len\s*=\s*360;/,
        'chunker uses a conservative IRC-safe max length'
    );

    $assert->ok(
        $chunker =~ /length\(\$line\)\s*\+\s*length\(\$piece\)\s*>\s*\$max_len/,
        'chunker checks line length before appending a command'
    );

    $assert->ok(
        $chunker =~ /botNotice\(\$self,\s*\$nick,\s*\$line\)/,
        'chunker sends completed lines through botNotice'
    );

    $assert->ok(
        $list =~ /_mbHelpSendChunkedList\(\$self,\s*\$nick,\s*"Public\/private: ",\s*\@public_like\)/,
        'public/private internal commands are sent through chunker'
    );

    $assert->ok(
        $list =~ /_mbHelpSendChunkedList\(\$self,\s*\$nick,\s*"Privileged\/admin: ",\s*\@privileged\)/,
        'privileged/admin internal commands are sent through chunker'
    );

    $assert->ok(
        $list !~ /join\(', ',\s*\@public_like\)/,
        'public/private list is no longer sent as one huge join() line'
    );

    $assert->ok(
        $list !~ /join\(', ',\s*\@privileged\)/,
        'privileged/admin list is no longer sent as one huge join() line'
    );
};
