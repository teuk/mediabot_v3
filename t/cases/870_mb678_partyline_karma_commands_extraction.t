# t/cases/870_mb678_partyline_karma_commands_extraction.t
# =============================================================================
# MB678-IV-F: Partyline karma visibility command extraction.
# =============================================================================
use strict;
use warnings;
use File::Spec;

sub _slurp_870 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $party = _slurp_870(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $cmds  = _slurp_870(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Commands.pm'));
    my $disp  = _slurp_870(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Dispatcher.pm'));

    $assert->like($cmds, qr/MB678-IV-F: karma visibility commands/,
        'IV-F extraction marker is present');

    my @methods = qw(_cmd_karma _cmd_karmahist);

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

    $assert->like($cmds, qr/Usage: \.karma <nick> \[#channel\]/,
        '.karma keeps its historical Partyline usage contract');
    $assert->like($cmds, qr/WHERE LOWER\(k\.nick\) = \?/,
        '.karma keeps cross-channel lookup by normalized nick');
    $assert->like($cmds, qr/k\.score <> 0/,
        '.karma keeps non-zero cross-channel filtering');
    $assert->like($cmds, qr/my \$klog = \$bot->\{_karma_log\}\{\$chan\} \/\/ \[\];/,
        '.karmahist keeps in-memory channel history source');
    $assert->like($cmds, qr/\@entries = \@entries\[0\.\.9\] if \@entries > 10/,
        '.karmahist remains capped to ten Partyline entries');
    $assert->like($cmds, qr/Mediabot::UserCommands::_seconds_to_human/,
        '.karmahist keeps human-readable age formatting');

    $assert->like($party, qr/^sub _cmd_bans \{/m,
        'moderation family remains in Partyline after later extractions');
    $assert->unlike($cmds, qr/^sub _cmd_bans \{/m,
        'command extractions do not broaden into the moderation family yet');

    $assert->unlike($cmds, qr/^sub _handle_line \{/m,
        'dispatcher responsibility is not duplicated in Commands.pm');
    $assert->unlike($cmds, qr/^sub _do_login \{/m,
        'authentication responsibility is not duplicated in Commands.pm');
};
