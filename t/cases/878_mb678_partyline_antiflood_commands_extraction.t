# t/cases/878_mb678_partyline_antiflood_commands_extraction.t
# =============================================================================
# MB678-IV-M: Partyline anti-flood/cooldown operator command extraction.
# =============================================================================
use strict;
use warnings;
use File::Spec;

sub _slurp_878 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $party = _slurp_878(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $cmds  = _slurp_878(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Commands.pm'));
    my $disp  = _slurp_878(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Dispatcher.pm'));

    $assert->like($cmds, qr/MB678-IV-M: anti-flood and cooldown operator commands/,
        'IV-M extraction marker is present');

    my @methods = qw(
        _cmd_floodset
        _cmd_cmdcooldown
        _cmd_netsplit
        _cmd_floodstatus
        _cmd_flushcooldown
    );

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

    $assert->like($cmds, qr/\$bot->\{_chan_flood_conf\}\{\$chan\}/,
        '.floodset keeps per-channel flood override storage');
    $assert->like($cmds, qr/delete \$bot->\{_chan_flood\}\{\$chan\}/,
        '.floodset keeps current channel flood-state reset');
    $assert->like($cmds, qr/warn_only\s*=>\s*\$warn_only/,
        '.floodset keeps warn-only control');

    $assert->like($cmds, qr/\$bot->\{_cmd_cooldown_conf\}\{\$chan\}\{\$cmd\}\s*=\s*\$secs/,
        '.cmdcooldown keeps per-command cooldown configuration');
    $assert->like($cmds, qr/\$secs = 0 if \$secs < 0; \$secs = 3600 if \$secs > 3600/,
        '.cmdcooldown keeps its 0..3600 clamp');

    $assert->like($cmds, qr/_netsplit_quit_count/,
        '.netsplit keeps netsplit counters');
    $assert->like($cmds, qr/gethChannelsNicksOnChan\(\$chan\)/,
        '.netsplit keeps channel nicklist visibility');

    $assert->like($cmds, qr/Channel antiflood \(AF1/,
        '.floodstatus keeps AF1 output state');
    $assert->like($cmds, qr/Channel flood \(AF4/,
        '.floodstatus keeps AF4 input state');
    $assert->like($cmds, qr/Per-nick flood \(AF3/,
        '.floodstatus keeps AF3 per-nick state');
    $assert->like($cmds, qr/Temp mutes \(CC3\/AF7\)/,
        '.floodstatus keeps temporary mute visibility');

    $assert->like($cmds, qr/delete \$bot->\{_karma_cooldown\}/,
        '.flushcooldown keeps karma cooldown clearing');
    $assert->like($cmds, qr/All karma cooldowns cleared\./,
        '.flushcooldown keeps global-clear confirmation');

    $assert->like($party, qr/^sub _cmd_history \{/m,
        '.history remains in Partyline after IV-M');
    $assert->unlike($cmds, qr/^sub _cmd_history \{/m,
        'IV-M does not broaden into session history');

    $assert->like($party, qr/^sub _cmd_eval \{/m,
        '.eval remains in Partyline after IV-M');
    $assert->unlike($cmds, qr/^sub _cmd_eval \{/m,
        'IV-M does not broaden into owner/developer eval');

    $assert->like($party, qr/^sub _cmd_die \{/m,
        '.die remains in Partyline after IV-M');
    $assert->unlike($cmds, qr/^sub _cmd_die \{/m,
        'IV-M does not broaden into process termination');

    $assert->unlike($cmds, qr/^sub _handle_line \{/m,
        'dispatcher responsibility is not duplicated in Commands.pm');
    $assert->unlike($cmds, qr/^sub _do_login \{/m,
        'authentication responsibility is not duplicated in Commands.pm');
};
