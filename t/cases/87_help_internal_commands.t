# t/cases/87_help_internal_commands.t
# =============================================================================
# Regression checks for real internal help.
#
# help <command> must distinguish:
#   - internal dispatch commands
#   - dynamic PUBLIC_COMMANDS entries
#   - unknown commands
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_help_internal_commands {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_help_internal_commands {
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

sub _extract_simple_dispatch_commands_help_internal_commands {
    my ($body) = @_;

    my %cmds;

    while (
        $body =~ /^\s*
            ([A-Za-z0-9_]+)
            \s*=>\s*
            sub\s*\{\s*
            [A-Za-z_][A-Za-z0-9_]*
            \s*\(\s*\$ctx\s*\)
            \s*\}
            \s*,?
        /mgx
    ) {
        $cmds{$1} = 1;
    }

    return sort keys %cmds;
}

sub _extract_help_table_commands_help_internal_commands {
    my ($src) = @_;

    my ($raw) = $src =~ /my\s+\$raw\s*=\s*<<'MEDIABOT_INTERNAL_HELP';\n(.*?)\nMEDIABOT_INTERNAL_HELP/s;
    return unless defined $raw;

    my %cmds;

    for my $line (split /\n/, $raw) {
        next if $line =~ /^\s*$/;
        my ($cmd) = split /\|/, $line, 2;
        $cmds{$cmd} = 1 if defined $cmd && length $cmd;
    }

    return sort keys %cmds;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_help_internal_commands(
        File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm')
    );

    $assert->ok(
        $src =~ /^sub\s+_mbHelpInternalCommands\s*\{/m,
        'internal help table function exists'
    );

    $assert->ok(
        $src =~ /^sub\s+_mbHelpPublicCommandExists\s*\{/m,
        'PUBLIC_COMMANDS lookup helper exists'
    );

    $assert->ok(
        $src =~ /^sub\s+_mbHelpSendInternalCommand\s*\{/m,
        'internal help sender exists'
    );

    $assert->ok(
        $src =~ /Internal command: \$cmd/,
        'help <internal command> sends an internal-command header'
    );

    $assert->ok(
        $src =~ /Syntax: /,
        'internal help includes syntax'
    );

    $assert->ok(
        $src =~ /Level: /,
        'internal help includes level'
    );

    $assert->ok(
        $src =~ /Description: /,
        'internal help includes description'
    );

    $assert->ok(
        $src =~ /SELECT 1 FROM PUBLIC_COMMANDS WHERE command = \? LIMIT 1/,
        'help checks PUBLIC_COMMANDS entries after internal help, including on-hold commands'
    );

    $assert->ok(
        $src =~ /return mbDbShowCommand_ctx\(\$ctx\)/,
        'help <PUBLIC_COMMANDS command> delegates to showcmd'
    );

    $assert->ok(
        $src !~ /Try: showcmd \$cmd/,
        'help no longer blindly suggests showcmd for every command'
    );

    my $public_body = _extract_sub_body_help_internal_commands($src, 'mbCommandPublic');
    my $private_body = _extract_sub_body_help_internal_commands($src, 'mbCommandPrivate');

    $assert->ok(
        defined $public_body,
        'mbCommandPublic body found'
    );

    $assert->ok(
        defined $private_body,
        'mbCommandPrivate body found'
    );

    my %dispatch_cmds;
    $dispatch_cmds{$_} = 1 for _extract_simple_dispatch_commands_help_internal_commands($public_body // '');
    $dispatch_cmds{$_} = 1 for _extract_simple_dispatch_commands_help_internal_commands($private_body // '');

    my %help_cmds;
    $help_cmds{$_} = 1 for _extract_help_table_commands_help_internal_commands($src);

    my @missing = grep { !$help_cmds{$_} } sort keys %dispatch_cmds;

    $assert->is(
        join(', ', @missing),
        '',
        'every simple internal dispatch command has a help entry'
    );

    for my $cmd (qw(weather topic showcmd help listeners nextsong update)) {
        $assert->ok(
            $help_cmds{$cmd},
            "internal help table contains $cmd"
        );
    }
};
