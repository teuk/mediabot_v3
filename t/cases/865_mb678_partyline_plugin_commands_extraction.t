# t/cases/865_mb678_partyline_plugin_commands_extraction.t
# =============================================================================
# MB678-IV-A: Partyline plugin command extraction contract.
# =============================================================================
use strict;
use warnings;
use File::Spec;

sub _slurp_865 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $party = _slurp_865(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $cmds  = _slurp_865(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Commands.pm'));
    my $disp  = _slurp_865(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Dispatcher.pm'));

    $assert->like($party, qr/use Mediabot::Partyline::Commands qw\(/,
        'Partyline imports the extracted command API');
    $assert->like($cmds, qr/^package Mediabot::Partyline::Commands;/m,
        'Commands module has its dedicated package');
    $assert->like($cmds, qr/MB678-IV-A: Partyline plugin\/ScriptDryRun command extraction/,
        'MB678-IV-A extraction marker is present');

    my @methods = qw(
        _cmd_scriptdryrun _plugin_info_text _plugin_config_display_value _cmd_plugins
    );
    for my $name (@methods) {
        my $in_parent = () = $party =~ /^sub\s+\Q$name\E\s*\{/mg;
        my $in_cmds   = () = $cmds  =~ /^sub\s+\Q$name\E\s*\{/mg;
        $assert->is($in_parent, 0, "$name implementation left Partyline.pm");
        $assert->is($in_cmds, 1, "$name implemented exactly once in Commands.pm");
        $assert->like($party, qr/^\s*\Q$name\E\s*$/m,
            "$name remains imported into Partyline");
    }

    $assert->like($party, qr/^sub _cmd_help \{/m,
        'generic Partyline help intentionally remains in Partyline during IV-A');
    $assert->unlike($cmds, qr/^sub _cmd_help \{/m,
        'IV-A does not broaden into unrelated command extraction');
    $assert->like($disp, qr/->_cmd_scriptdryrun\(/,
        'dispatcher still routes .scriptdryrun through historical method surface');
    $assert->like($disp, qr/->_cmd_plugins\(/,
        'dispatcher still routes .plugins through historical method surface');
    $assert->unlike($cmds, qr/^sub _handle_line \{/m,
        'dispatcher responsibility is not duplicated in Commands.pm');
    $assert->unlike($cmds, qr/^sub _do_login \{/m,
        'authentication responsibility is not duplicated in Commands.pm');

    my $party_lines = () = $party =~ /\n/g;
    $assert->ok($party_lines < 4300,
        'Partyline monolith is materially smaller after IV-A extraction');
};
