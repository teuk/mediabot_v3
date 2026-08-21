# t/cases/876_mb678_partyline_runtime_diagnostics_commands_extraction.t
# =============================================================================
# MB678-IV-K: Partyline runtime diagnostics/status command extraction.
# =============================================================================
use strict;
use warnings;
use File::Spec;

sub _slurp_876 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $party = _slurp_876(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $cmds  = _slurp_876(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Commands.pm'));
    my $disp  = _slurp_876(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Dispatcher.pm'));

    $assert->like($cmds, qr/MB678-IV-K: runtime diagnostics and status commands/,
        'IV-K extraction marker is present');

    my @methods = qw(
        _cmd_ping
        _cmd_uptime
        _cmd_dccstat
        _cmd_stat
        _cmd_dbstats
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

    $assert->like($cmds, qr/PONG %02d:%02d:%02d/,
        '.ping keeps timestamped PONG output');

    $assert->like($cmds, qr/Mediabot::Helpers::getProcessStartTimestamp\(\$bot, \$now\)/,
        '.uptime keeps the shared process-start helper');
    $assert->like($cmds, qr/\$self->_format_duration\(\$bot_uptime\)/,
        '.uptime keeps the shared duration formatter');
    $assert->like($cmds, qr/Claude AI:/,
        '.uptime keeps Claude observability section');

    $assert->like($cmds, qr/\$self->_resolve_dcc_public_ip\(\$bot\)/,
        '.dccstat keeps the shared DCC public-IP resolver');
    $assert->like($cmds, qr/\$self->_dcc_listen_port\(\$bot\)/,
        '.dccstat keeps the shared DCC listen-port helper');
    $assert->like($cmds, qr/\$self->_dcc_offers_snapshot/,
        '.dccstat keeps pending-offer snapshot visibility');

    $assert->like($cmds, qr/my \$stat_cache_key = '_stat_cache'/,
        '.stat keeps its short-lived cache');
    $assert->like($cmds, qr/WHERE uc\.level = 500/,
        '.stat keeps channel owner lookup');
    $assert->like($cmds, qr/mediabot_commands_partyline_total/,
        '.stat keeps Partyline command metrics');
    $assert->like($cmds, qr/Memory: \$\{mem\} MB RSS/,
        '.stat keeps process RSS visibility');

    $assert->like($cmds, qr/SHOW STATUS LIKE '\$like'/,
        '.dbstats keeps MariaDB status lookup');
    $assert->like($cmds, qr/Threads_connected/,
        '.dbstats keeps connection-count visibility');
    $assert->like($cmds, qr/mediabot_karmahist_requests_total/,
        '.dbstats keeps bot request counters');

    $assert->like($party, qr/^sub _cmd_bans \{/m,
        'moderation family remains in Partyline after IV-K');
    $assert->unlike($cmds, qr/^sub _cmd_bans \{/m,
        'IV-K does not broaden into moderation');

    $assert->like($party, qr/^sub _cmd_eval \{/m,
        '.eval remains in Partyline after IV-K');
    $assert->unlike($cmds, qr/^sub _cmd_eval \{/m,
        'IV-K does not broaden into .eval');

    $assert->unlike($cmds, qr/^sub _handle_line \{/m,
        'dispatcher responsibility is not duplicated in Commands.pm');
    $assert->unlike($cmds, qr/^sub _do_login \{/m,
        'authentication responsibility is not duplicated in Commands.pm');
};
