# t/cases/877_mb678_partyline_channel_moderation_commands_extraction.t
# =============================================================================
# MB678-IV-L: Partyline channel moderation/control command extraction.
# =============================================================================
use strict;
use warnings;
use File::Spec;

sub _slurp_877 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $party = _slurp_877(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $cmds  = _slurp_877(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Commands.pm'));
    my $disp  = _slurp_877(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Dispatcher.pm'));

    $assert->like($cmds, qr/MB678-IV-L: channel moderation and control commands/,
        'IV-L extraction marker is present');

    my @methods = qw(
        _cmd_bans
        _cmd_ban
        _cmd_unban
        _cmd_topic
        _cmd_kick
        _cmd_unmute
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

    $assert->like($cmds, qr/list_active_bans\(\$id_channel, 11\)/,
        '.bans keeps bounded active-ban listing');
    $assert->like($cmds, qr/Mediabot::Helpers::channel_id_cached\(\$bot, \$chan\)/,
        'moderation commands keep central channel-id helper');

    $assert->like($cmds, qr/pending_whois_token.*?= \$ban_token/s,
        '.ban keeps per-session WHOIS token guard');
    $assert->like($cmds, qr/token\s*=>\s*\$ban_token/,
        '.ban keeps WHOIS_VARS token guard');
    $assert->like($cmds, qr/send_message\('WHOIS', undef, \$nick_target\)/,
        '.ban keeps asynchronous WHOIS request path');

    $assert->like($cmds, qr/mark_removed\(/,
        '.unban keeps ChannelBan removal path');
    $assert->like($cmds, qr/send_message\('MODE', undef, \$chan, '-b', \$target\)/,
        '.unban keeps IRC MODE -b path');

    $assert->like($cmds, qr/send_message\('TOPIC', undef, \$chan, \$topic\)/,
        '.topic keeps IRC TOPIC path');

    $assert->like($cmds, qr/Partyline \.kick failed/,
        '.kick keeps stable operation-error context');
    $assert->like($cmds, qr/\$self->_report_operation_error\(/,
        '.kick keeps centralized error redaction');

    $assert->like($cmds, qr/delete \$bot->\{_nick_mute\}\{\$target\}/,
        '.unmute keeps nick mute removal');

    $assert->like($party, qr/^sub _cmd_eval \{/m,
        '.eval remains in Partyline after IV-L');
    $assert->unlike($cmds, qr/^sub _cmd_eval \{/m,
        'IV-L does not broaden into .eval');

    $assert->like($party, qr/^sub _cmd_history \{/m,
        '.history remains in Partyline after IV-L');
    $assert->unlike($cmds, qr/^sub _cmd_history \{/m,
        'IV-L does not broaden into channel history');

    $assert->unlike($cmds, qr/^sub _handle_line \{/m,
        'dispatcher responsibility is not duplicated in Commands.pm');
    $assert->unlike($cmds, qr/^sub _do_login \{/m,
        'authentication responsibility is not duplicated in Commands.pm');
};
