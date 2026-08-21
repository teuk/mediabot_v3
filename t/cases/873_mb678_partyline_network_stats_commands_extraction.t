# t/cases/873_mb678_partyline_network_stats_commands_extraction.t
# =============================================================================
# MB678-IV-H: Partyline network visibility/statistics command extraction.
# =============================================================================
use strict;
use warnings;
use File::Spec;

sub _slurp_873 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $party = _slurp_873(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $cmds  = _slurp_873(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Commands.pm'));
    my $disp  = _slurp_873(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Dispatcher.pm'));

    $assert->like($cmds, qr/MB678-IV-H: network visibility and statistics commands/,
        'IV-H extraction marker is present');

    my @methods = qw(_cmd_lusers _cmd_stats);
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

    $assert->like($cmds, qr/Network stats: none yet \(no LUSERS numerics received\)/,
        '.lusers keeps its empty-cache response');
    $assert->like($cmds, qr/LUSERS refresh requested; values below are pre-refresh\./,
        '.lusers keeps its refresh acknowledgement');
    $assert->like($cmds, qr/LUSERS refresh not sent \(not connected\)\./,
        '.lusers keeps its disconnected refresh response');
    $assert->like($cmds, qr/mb544-B1/,
        '.lusers keeps the mb544 source marker');

    $assert->like($cmds, qr/No channel\. Usage: \.stats \[#channel\]/,
        '.stats keeps its no-channel usage response');
    $assert->like($cmds, qr/Top speakers:/,
        '.stats keeps top-speaker output');
    $assert->like($cmds, qr/Top karma:/,
        '.stats keeps top-karma output');
    $assert->like($cmds, qr/Mediabot::Helpers::channel_id_cached\(\$bot, \$chan\)/,
        '.stats keeps the shared channel-id cache helper');

    $assert->like($party, qr/^sub _cmd_ai \{/m,
        'large AI command family remains in Partyline after IV-H');
    $assert->unlike($cmds, qr/^sub _cmd_ai \{/m,
        'IV-H does not broaden into the AI command family');

    $assert->unlike($cmds, qr/^sub _handle_line \{/m,
        'dispatcher responsibility is not duplicated in Commands.pm');
    $assert->unlike($cmds, qr/^sub _do_login \{/m,
        'authentication responsibility is not duplicated in Commands.pm');
};
