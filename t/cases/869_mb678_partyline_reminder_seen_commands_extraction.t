# t/cases/869_mb678_partyline_reminder_seen_commands_extraction.t
# =============================================================================
# MB678-IV-E: Partyline reminder / seen command extraction.
# =============================================================================
use strict;
use warnings;
use File::Spec;

sub _slurp_869 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $party = _slurp_869(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $cmds  = _slurp_869(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Commands.pm'));
    my $disp  = _slurp_869(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Dispatcher.pm'));

    $assert->like($cmds, qr/MB678-IV-E: reminder \/ seen commands/,
        'IV-E extraction marker is present');

    my @methods = qw(_cmd_remind _cmd_seen _cmd_purgereminders);

    for my $name (@methods) {
        my $in_parent = () = $party =~ /^sub\s+\Q$name\E\s*\{/mg;
        my $in_cmds   = () = $cmds  =~ /^sub\s+\Q$name\E\s*\{/mg;

        $assert->is($in_parent, 0, "$name implementation left Partyline.pm");
        $assert->is($in_cmds, 1, "$name implemented exactly once in Commands.pm");
        $assert->like($party, qr/^\s*\Q$name\E\s*$/m,
            "$name remains imported into Partyline");
        $assert->like($disp, qr/->\Q$name\E\(/,
            "dispatcher still routes through historical $name surface");
    }

    $assert->like($cmds, qr/mb93-B3: valider le nick destinataire/,
        '.remind keeps target-nick validation');
    $assert->like($cmds,
        qr/Mediabot::Helpers::channel_id_cached\(\$bot, \$chan_name\)/,
        '.remind keeps cached channel-id lookup');
    $assert->like($cmds, qr/mb94-B1 \/ mb127-B3: support wildcard/,
        '.seen keeps escaped wildcard handling');
    $assert->like($cmds, qr/FROM USER_SEEN WHERE nick LIKE \? ESCAPE '!'/,
        '.seen keeps escaped SQL LIKE query');
    $assert->like($cmds, qr/DELETE FROM REMINDERS\s+WHERE delivered > 0/s,
        '.purgereminders keeps bounded delivered-reminder cleanup');

    $assert->unlike($party, qr/^sub _cmd_karma \{/m,
        'later IV-F extraction removes karma implementation from Partyline.pm');
    $assert->like($cmds, qr/^sub _cmd_karma \{/m,
        'later IV-F extraction places karma implementation in Commands.pm');

    $assert->unlike($cmds, qr/^sub _handle_line \{/m,
        'dispatcher responsibility is not duplicated in Commands.pm');
    $assert->unlike($cmds, qr/^sub _do_login \{/m,
        'authentication responsibility is not duplicated in Commands.pm');
};
