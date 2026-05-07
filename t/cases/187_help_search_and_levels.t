# t/cases/187_help_search_and_levels.t
# =============================================================================
# Regression checks for improved internal help.
#
# help should support:
#   help search <term>
#   help level <level>
#
# The internal help parser should also ignore duplicate command rows safely.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_187 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_187 {
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

    my $src = _slurp_187(
        File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm')
    );

    my $parse_body  = _extract_sub_body_187($src, '_mbHelpInternalCommands');
    my $search_body = _extract_sub_body_187($src, '_mbHelpSendSearchResults');
    my $level_body  = _extract_sub_body_187($src, '_mbHelpSendLevelResults');
    my $help_body   = _extract_sub_body_187($src, 'mbHelp_ctx');

    $assert->ok(defined $parse_body,  '_mbHelpInternalCommands body found');
    $assert->ok(defined $search_body, '_mbHelpSendSearchResults body found');
    $assert->ok(defined $level_body,  '_mbHelpSendLevelResults body found');
    $assert->ok(defined $help_body,   'mbHelp_ctx body found');

    $assert->like(
        $src,
        qr/help \[#channel\|command\|docs\|search <term>\|level <level>\]/,
        'help entry documents search and level modes'
    );

    $assert->like(
        $parse_body // '',
        qr/next if exists \$help\{\$key\};/,
        'internal help parser ignores duplicate command rows'
    );

    $assert->like(
        $search_body // '',
        qr/Syntax: help search <term>/,
        'help search has syntax message'
    );

    $assert->like(
        $search_body // '',
        qr/Internal help matches for/,
        'help search reports matches'
    );

    $assert->like(
        $search_body // '',
        qr/Showing 25 of/,
        'help search limits noisy output'
    );

    $assert->like(
        $level_body // '',
        qr/Syntax: help level <public\|private\|admin\|owner\|master\|authorized\|operator>/,
        'help level has syntax message'
    );

    $assert->like(
        $level_body // '',
        qr/Internal commands for level/,
        'help level reports matching commands'
    );

    $assert->like(
        $help_body // '',
        qr/\$first =~ \/\^\(\?:search\|find\|grep\)\$/,
        'mbHelp_ctx dispatches help search aliases'
    );

    $assert->like(
        $help_body // '',
        qr/\$first =~ \/\^\(\?:level\|role\)\$/,
        'mbHelp_ctx dispatches help level aliases'
    );

    $assert->unlike(
        $src,
        qr/openai\|openai \[status\|config\]\|owner\|Show safe OpenAI\/tellme runtime configuration/,
        'obsolete duplicate openai help row is removed'
    );
};
