# t/cases/866_mb678_partyline_core_commands_extraction.t
# =============================================================================
# MB678-IV-B: Partyline core operator/session command extraction contract.
# =============================================================================
use strict;
use warnings;
use File::Spec;

sub _slurp_866 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $party = _slurp_866(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $cmds  = _slurp_866(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Commands.pm'));
    my $disp  = _slurp_866(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Dispatcher.pm'));

    $assert->like($party, qr/use Mediabot::Partyline::Commands qw\(/,
        'Partyline imports the extracted command API');
    $assert->like($cmds, qr/MB678-IV-B: core operator\/session commands/,
        'IV-B extraction marker is present');

    my @methods = qw(
        _cmd_help _cmd_console _cmd_motd _send_motd _cmd_whom
        _cmd_match _cmd_boot _cmd_whois _cmd_log
    );

    for my $name (@methods) {
        my $in_parent = () = $party =~ /^sub\s+\Q$name\E\s*\{/mg;
        my $in_cmds   = () = $cmds  =~ /^sub\s+\Q$name\E\s*\{/mg;

        $assert->is($in_parent, 0, "$name implementation left Partyline.pm");
        $assert->is($in_cmds, 1, "$name implemented exactly once in Commands.pm");
        $assert->like($party, qr/^\s*\Q$name\E\s*$/m,
            "$name remains imported into Partyline");
    }

    $assert->like($cmds, qr/use Encode qw\(encode\);/,
        'Commands owns the UTF-8 console transport dependency');
    $assert->like($cmds, qr/Mediabot::Helpers::truncate_utf8\(\$line, 357\)/,
        '.match keeps UTF-8-safe hostmask truncation after extraction');

    for my $route (qw(_cmd_help _cmd_console _cmd_motd _cmd_whom _cmd_match _cmd_boot _cmd_whois _cmd_log)) {
        $assert->like($disp, qr/->\Q$route\E\(/,
            "dispatcher still routes through historical $route surface");
    }

    $assert->unlike($party, qr/^sub _cmd_timers \{/m,
        'scheduler command family may leave Partyline after IV-B');
    $assert->like($cmds, qr/^sub _cmd_timers \{/m,
        'Commands owns the scheduler command family after IV-C');
    $assert->unlike($cmds, qr/^sub _handle_line \{/m,
        'dispatcher responsibility is not duplicated in Commands.pm');
    $assert->unlike($cmds, qr/^sub _do_login \{/m,
        'authentication responsibility is not duplicated in Commands.pm');

    my $party_lines = () = $party =~ /\n/g;
    $assert->ok($party_lines < 3750,
        'Partyline monolith is materially smaller after IV-B extraction');
};
