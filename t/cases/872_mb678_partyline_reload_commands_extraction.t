# t/cases/872_mb678_partyline_reload_commands_extraction.t
# =============================================================================
# MB678-IV-G: Partyline configuration reload command extraction.
# =============================================================================
use strict;
use warnings;
use File::Spec;

sub _slurp_872 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $party = _slurp_872(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $cmds  = _slurp_872(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Commands.pm'));
    my $disp  = _slurp_872(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Dispatcher.pm'));

    $assert->like($cmds, qr/MB678-IV-G: configuration reload commands/,
        'IV-G extraction marker is present');

    my @methods = qw(
        _reload_configuration_file
        _cmd_reloadconf
        _cmd_reload
    );

    for my $name (@methods) {
        my $in_parent = () = $party =~ /^sub\s+\Q$name\E\s*\{/mg;
        my $in_cmds   = () = $cmds  =~ /^sub\s+\Q$name\E\s*\{/mg;

        $assert->is($in_parent, 0, "$name implementation left Partyline.pm");
        $assert->is($in_cmds, 1, "$name implemented exactly once in Commands.pm");
        $assert->like($party, qr/^\s*\Q$name\E\s*$/m,
            "$name remains imported into Partyline");
    }

    $assert->like($disp, qr/->_cmd_reloadconf\(/,
        'dispatcher still routes .reloadconf through historical surface');
    $assert->like($disp, qr/->_cmd_reload\(/,
        'dispatcher still routes .reload through historical surface');

    $assert->like($cmds, qr/sub _reload_configuration_file\s*\{/,
        'shared checked configuration reload helper moved with both commands');
    $assert->like($cmds, qr/unless \$conf->can\('reload'\)/,
        'reload helper still requires the real reload API');
    $assert->unlike($cmds, qr/\$self->\{bot\}\{conf\}->load\s*\(/,
        'obsolete configuration load API is not reintroduced');

    $assert->like($cmds, qr/Permission denied \(Owner required\)\./,
        '.reload keeps its Owner-only gate');
    $assert->like($cmds, qr/Configuration reload failed\./,
        '.reloadconf keeps its sealed client failure response');
    $assert->like($cmds, qr/Reload failed\./,
        '.reload keeps its sealed client failure response');

    $assert->like($party, qr/^sub _cmd_ping \{/m,
        'ping/uptime family remains in Partyline after later extractions');
    $assert->unlike($cmds, qr/^sub _cmd_ping \{/m,
        'reload and later command extractions do not broaden into ping/uptime');

    $assert->unlike($cmds, qr/^sub _handle_line \{/m,
        'dispatcher responsibility is not duplicated in Commands.pm');
    $assert->unlike($cmds, qr/^sub _do_login \{/m,
        'authentication responsibility is not duplicated in Commands.pm');
};
