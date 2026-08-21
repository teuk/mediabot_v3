# t/cases/879_mb678_partyline_remaining_standard_commands_extraction.t
# =============================================================================
# MB678-IV-N: remaining standard/operator Partyline command extraction.
# =============================================================================
use strict;
use warnings;
use File::Spec;

sub _slurp_879 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $party = _slurp_879(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $cmds  = _slurp_879(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Commands.pm'));
    my $disp  = _slurp_879(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Dispatcher.pm'));

    $assert->like($cmds, qr/MB678-IV-N: remaining standard\/operator Partyline commands/,
        'IV-N extraction marker is present');

    my @methods = qw(
        _cmd_history
        _cmd_say
        _cmd_who
        _cmd_chanlog
        _cmd_nickinfo
        _cmd_who_chan
        _cmd_kv
        _cmd_achievementprofile
    );

    for my $name (@methods) {
        my $in_parent = () = $party =~ /^sub\s+\Q$name\E\s*\{/mg;
        my $in_cmds   = () = $cmds  =~ /^sub\s+\Q$name\E\s*\{/mg;
        $assert->is($in_parent, 0, "$name implementation left Partyline.pm");
        $assert->is($in_cmds, 1, "$name implemented exactly once in Commands.pm");
        $assert->like($party, qr/^\s*\Q$name\E\s*$/m,
            "$name remains imported into Partyline");
    }

    for my $name (qw(
        _cmd_history
        _cmd_say
        _cmd_chanlog
        _cmd_nickinfo
        _cmd_who_chan
        _cmd_kv
        _cmd_achievementprofile
    )) {
        $assert->like($disp, qr/->\Q$name\E\(/,
            "dispatcher still routes through historical $name surface");
    }

    $assert->unlike($disp, qr/->_cmd_who\(/,
        'legacy _cmd_who is not reintroduced as a dispatcher route');
    $assert->like($disp, qr/->_cmd_who_chan\(/,
        'current .who #channel route remains _cmd_who_chan');

    $assert->like($cmds, qr/my \$hist = \$self->\{users\}\{\$id\}\{history\} \/\/ \[\]/,
        '.history keeps per-session history source');
    $assert->like($cmds, qr/\$bot->botPrivmsg\(\$target, \$msg\)/,
        '.say keeps botPrivmsg delivery path');
    $assert->like($cmds, qr/Partyline: \$nick sent to \$target: \$msg/,
        '.say keeps operator audit logging');
    $assert->like($cmds, qr/sub _cmd_who \{.*?gethChannelsNicksOnChan\(\$chan\)/s,
        'legacy _cmd_who keeps channel nick lookup');

    $assert->like($cmds, qr/sub _cmd_chanlog \{.*?event_type IN \('public','action'\)/s,
        '.logs keeps public/action-only conversation filter');

    $assert->like($cmds, qr/sub _cmd_nickinfo \{.*?Last login:/s,
        '.nickinfo keeps last-login visibility');
    $assert->like($cmds, qr/sub _cmd_who_chan \{.*?mode_for_nick/s,
        '.who #channel keeps IRC op/voice mode visibility');
    $assert->like($cmds, qr/sub _cmd_who_chan \{.*?USER_CHANNEL/s,
        '.who #channel keeps registered-user level lookup');

    $assert->like($cmds, qr/my \$store = \$bot->\{_kv\} \/\/= \{\}/,
        '.kv keeps in-memory store');
    $assert->like($cmds, qr/Use set\/get\/del\/list/,
        '.kv keeps existing operation set');

    $assert->like($cmds, qr/identity_profile_diagnostic\(\$nick, \$channel\)/,
        '.achievementprofile keeps durable identity diagnostic API');
    $assert->like($cmds, qr/Achievement identity diagnostic \(read-only\)/,
        '.achievementprofile remains explicitly read-only');

    $assert->like($party, qr/^sub _cmd_eval \{/m,
        '.eval remains in Partyline for dedicated privileged-control round');
    $assert->unlike($cmds, qr/^sub _cmd_eval \{/m,
        'IV-N does not broaden into .eval');
    $assert->like($party, qr/^sub _cmd_die \{/m,
        '.die remains in Partyline for dedicated privileged-control round');
    $assert->unlike($cmds, qr/^sub _cmd_die \{/m,
        'IV-N does not broaden into .die');

    for my $core (qw(new get_port _runtime_status_path _runtime_status_payload _write_runtime_status)) {
        $assert->like($party, qr/^sub\s+\Q$core\E\s*\{/m,
            "$core remains in Partyline core");
        $assert->unlike($cmds, qr/^sub\s+\Q$core\E\s*\{/m,
            "$core is not duplicated in Commands");
    }

    $assert->unlike($cmds, qr/^sub _handle_line \{/m,
        'dispatcher responsibility is not duplicated in Commands.pm');
    $assert->unlike($cmds, qr/^sub _do_login \{/m,
        'authentication responsibility is not duplicated in Commands.pm');
};
