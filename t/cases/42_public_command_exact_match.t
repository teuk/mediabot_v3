# t/cases/42_public_command_exact_match.t
# =============================================================================
# Static regression checks for exact public command lookup.
#
# Public command names are identifiers, not LIKE patterns. Using LIKE means
# command names containing '%' or '_' can match unintended commands.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_public_command_exact_match {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_public_command_exact_match(File::Spec->catfile('.', 'Mediabot', 'DBCommands.pm'));

    $assert->ok(
        $src =~ /SELECT command FROM PUBLIC_COMMANDS WHERE command = \?/,
        'addcmd duplicate check uses exact command match'
    );

    $assert->ok(
        $src =~ /SELECT id_user, id_public_commands FROM PUBLIC_COMMANDS WHERE command = \?/,
        'remcmd lookup uses exact command match'
    );

    my $hold_lookup_count = () = $src =~ /SELECT id_public_commands, id_user FROM PUBLIC_COMMANDS WHERE command = \?/g;
    $assert->ok(
        $hold_lookup_count >= 2,
        'holdcmd/unholdcmd lookups use exact command match'
    );

    $assert->ok(
        $src =~ /WHERE PC\.command = \?/,
        'showcmd lookup uses exact command match'
    );

    $assert->ok(
        $src =~ /WHERE command = \? AND active = 1/,
        'runtime public command execution uses exact command match'
    );

    $assert->ok(
        $src !~ /PUBLIC_COMMANDS WHERE command LIKE \?/,
        'DBCommands no longer uses command LIKE for PUBLIC_COMMANDS direct lookup'
    );

    $assert->ok(
        $src !~ /PC\.command LIKE \?/,
        'DBCommands no longer uses PC.command LIKE for showcmd'
    );
};
