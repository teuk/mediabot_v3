# t/cases/874_mb678_partyline_irc_control_commands_extraction.t
# =============================================================================
# MB678-IV-I: Partyline IRC control/lifecycle command extraction.
# =============================================================================
use strict;
use warnings;
use File::Spec;

sub _slurp_874 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $party = _slurp_874(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $cmds  = _slurp_874(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Commands.pm'));
    my $priv  = _slurp_874(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Privileged.pm'));
    my $disp  = _slurp_874(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Dispatcher.pm'));

    $assert->like($cmds, qr/MB678-IV-I: IRC control and lifecycle commands/,
        'IV-I extraction marker is present');

    my @methods = qw(
        _cmd_join
        _cmd_part
        _cmd_nick
        _cmd_raw
        _cmd_rehash
        _cmd_restart
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

    $assert->like($cmds, qr/joinChannel\(\$chan,\s*\$key\)/,
        '.join still forwards the real channel key to joinChannel');
    $assert->like($cmds, qr/key: \[redacted\]/,
        '.join logging still redacts channel keys');
    $assert->unlike($cmds, qr/key: \$key|with key \$key/,
        '.join does not expose raw channel keys');

    $assert->like($cmds, qr/partChannel\(\$chan,\s*"Partyline requested part"\)/,
        '.part keeps the existing IRC part request');
    $assert->like($cmds, qr/stop_channel_nicklist_timer\(\$chan\)/,
        '.part keeps nicklist timer cleanup');

    $assert->like($cmds, qr/change_nick\(\$newnick\)/,
        '.nick keeps the IRC nick-change call');
    $assert->like($cmds, qr/Invalid nick format\./,
        '.nick keeps format validation');

    $assert->like($cmds, qr/Access denied: \.raw requires Owner level\./,
        '.raw keeps its Owner-only gate');
    $assert->like($cmds, qr/\$raw =~ s\/\[\\r\\n\]\/\/g/,
        '.raw keeps CR/LF stripping before IRC write');

    $assert->like($cmds, qr/Access denied: \.rehash requires Master or Owner level\./,
        '.rehash keeps its Master-or-Owner gate');
    $assert->like($cmds, qr/rehash_runtime_state\(\)/,
        '.rehash keeps the runtime-state rehash path');

    $assert->like($cmds, qr/Access denied: \.restart requires Owner level\./,
        '.restart keeps its Owner-only gate');
    $assert->like($cmds, qr/restart_irc\(reason => \$msg\)/,
        '.restart keeps the in-process IRC restart path');
    $assert->like($cmds, qr/\$self->_broadcast\("\*\*\* IRC restarting - bot will reconnect shortly\. \*\*\*"\)/,
        '.restart keeps Partyline restart broadcast');
    $assert->unlike($party, qr/^sub _cmd_eval \{/m,
        '.eval implementation has left Partyline after IV-O');
    $assert->like($priv, qr/^sub _cmd_eval \{/m,
        '.eval privileged control is isolated in Privileged');
    $assert->unlike($cmds, qr/^sub _cmd_eval \{/m,
        '.eval is not duplicated in Commands.pm');

    $assert->unlike($party, qr/^sub _cmd_say \{/m,
        'later IV-N extraction removes .say implementation from Partyline');
    $assert->like($cmds, qr/^sub _cmd_say \{/m,
        'later IV-N extraction places .say implementation in Commands');
    $assert->unlike($party, qr/^sub _cmd_who \{/m,
        'later IV-N extraction removes legacy _cmd_who implementation from Partyline');
    $assert->like($cmds, qr/^sub _cmd_who \{/m,
        'later IV-N extraction preserves legacy _cmd_who in Commands');

    $assert->unlike($cmds, qr/^sub _handle_line \{/m,
        'dispatcher responsibility is not duplicated in Commands.pm');
    $assert->unlike($cmds, qr/^sub _do_login \{/m,
        'authentication responsibility is not duplicated in Commands.pm');
};
