# t/cases/867_mb678_partyline_operational_commands_extraction.t
# =============================================================================
# MB678-IV-C: Partyline scheduler / operational status command extraction.
# =============================================================================
use strict;
use warnings;
use File::Spec;

sub _slurp_867 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $party = _slurp_867(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $cmds  = _slurp_867(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Commands.pm'));
    my $disp  = _slurp_867(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Dispatcher.pm'));

    $assert->like($cmds, qr/MB678-IV-C: scheduler \/ operational status commands/,
        'IV-C extraction marker is present');

    my @methods = qw(
        _cmd_timers _format_duration _seconds_to_human
        _cmd_schedule _cmd_status _cmd_metrics
    );

    for my $name (@methods) {
        my $in_parent = () = $party =~ /^sub\s+\Q$name\E\s*\{/mg;
        my $in_cmds   = () = $cmds  =~ /^sub\s+\Q$name\E\s*\{/mg;

        $assert->is($in_parent, 0, "$name implementation left Partyline.pm");
        $assert->is($in_cmds, 1, "$name implemented exactly once in Commands.pm");
        $assert->like($party, qr/^\s*\Q$name\E\s*$/m,
            "$name remains imported into Partyline");
    }

    for my $route (qw(_cmd_timers _cmd_schedule _cmd_status _cmd_metrics)) {
        $assert->like($disp, qr/->\Q$route\E\(/,
            "dispatcher still routes through historical $route surface");
    }

    $assert->like($cmds, qr/^sub _format_duration \{/m,
        'duration formatter travels with the operational commands');
    $assert->like($cmds, qr/^sub _seconds_to_human \{/m,
        'human duration helper travels with the operational commands');

    $assert->unlike($party, qr/^sub _cmd_channels \{/m,
        'channel/network command family may leave Partyline after IV-C');
    $assert->like($cmds, qr/^sub _cmd_channels \{/m,
        'Commands owns the channel/network family after IV-D');

    $assert->unlike($cmds, qr/^sub _handle_line \{/m,
        'dispatcher responsibility is not duplicated in Commands.pm');
    $assert->unlike($cmds, qr/^sub _do_login \{/m,
        'authentication responsibility is not duplicated in Commands.pm');

    my $party_lines = () = $party =~ /\n/g;
    $assert->ok($party_lines < 3300,
        'Partyline monolith is materially smaller after IV-C extraction');
};
