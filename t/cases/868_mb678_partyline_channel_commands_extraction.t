# t/cases/868_mb678_partyline_channel_commands_extraction.t
# =============================================================================
# MB678-IV-D: Partyline channel / network visibility command extraction.
# =============================================================================
use strict;
use warnings;
use File::Spec;

sub _slurp_868 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $party = _slurp_868(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $cmds  = _slurp_868(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Commands.pm'));
    my $disp  = _slurp_868(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Dispatcher.pm'));

    $assert->like($cmds, qr/MB678-IV-D: channel \/ network visibility commands/,
        'IV-D extraction marker is present');

    my @methods = qw(_cmd_channels _cmd_bcast _cmd_whochan _cmd_top);

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

    $assert->like($cmds,
        qr/Mediabot::Helpers::botPrivmsg\(\$bot, \$name, "\[broadcast\] \$msg"\)/,
        '.bcast keeps the helper-based IRC send path');
    $assert->like($cmds, qr/mb122-B2:/,
        '.top keeps the channel-digit parsing regression guard');
    $assert->like($cmds, qr/mb124-B4:/,
        '.top keeps standalone numeric limit parsing');

    $assert->unlike($party, qr/^sub _cmd_remind \{/m,
        'later IV-E extraction removes _cmd_remind from Partyline.pm');
    $assert->like($cmds, qr/^sub _cmd_remind \{/m,
        'later IV-E extraction places _cmd_remind in Commands.pm');
    $assert->like($party, qr/^sub _cmd_karma \{/m,
        'karma family remains in Partyline after IV-E');

    $assert->unlike($cmds, qr/^sub _handle_line \{/m,
        'dispatcher responsibility is not duplicated in Commands.pm');
    $assert->unlike($cmds, qr/^sub _do_login \{/m,
        'authentication responsibility is not duplicated in Commands.pm');

    my $party_lines = () = $party =~ /\n/g;
    $assert->ok($party_lines < 3000,
        'Partyline monolith falls below 3000 lines after IV-D extraction');
};
