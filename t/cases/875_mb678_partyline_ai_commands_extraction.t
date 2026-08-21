# t/cases/875_mb678_partyline_ai_commands_extraction.t
# =============================================================================
# MB678-IV-J: Partyline Claude/AI command extraction.
# =============================================================================
use strict;
use warnings;
use File::Spec;

sub _slurp_875 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $party = _slurp_875(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $cmds  = _slurp_875(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Commands.pm'));
    my $disp  = _slurp_875(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Dispatcher.pm'));

    $assert->like($cmds, qr/MB678-IV-J: Claude \/ AI commands/,
        'IV-J extraction marker is present');

    my @methods = qw(
        _cmd_ai
        _cmd_persona
        _cmd_quota
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

    $assert->like($cmds, qr/use Mediabot::External \(\);/,
        'Commands.pm loads the Claude external namespace required by .ai');
    $assert->like($cmds, qr/Mediabot::External::claudeAI\(/,
        '.ai keeps the existing Claude call path');
    $assert->like($cmds, qr/my \$output_fn = sub \{/,
        '.ai keeps callback-based Partyline output');
    $assert->unlike($cmds, qr/local \\?\*.*botPrivmsg/,
        '.ai does not reintroduce botPrivmsg monkey-patching');

    $assert->like($cmds, qr/if \(\$subcmd eq 'summary'\) \{.{0,400}?\$pl_level <= 2/s,
        '.ai summary keeps Administrator-or-better Partyline gate');
    $assert->like($cmds, qr/event_type IN \('public','action'\)/,
        '.ai summary keeps public/action CHANNEL_LOG filtering');
    $assert->like($cmds, qr/return \$self->_cmd_quota\(\$stream, \$id, lc\(\$pl_nick\)\)/,
        '.ai quota keeps delegation through historical _cmd_quota surface');
    $assert->like($cmds, qr/\$self->_report_operation_error\(/,
        '.ai keeps sealed operation-error reporting');

    $assert->like($cmds, qr/Active Claude personas:/,
        '.persona keeps active-persona visibility');
    $assert->like($cmds, qr/Persona cleared for \$target/,
        '.persona keeps explicit clear behaviour');

    $assert->like($cmds, qr/_claude_ratelimit/,
        '.quota keeps Claude rate-limit state');
    $assert->like($cmds, qr/anthropic\.RATE_MAX/,
        '.quota keeps configured request limit');
    $assert->like($cmds, qr/anthropic\.RATE_WINDOW/,
        '.quota keeps configured rate window');

    $assert->like($party, qr/^sub _cmd_ping \{/m,
        'ping/uptime family remains in Partyline after IV-J');
    $assert->unlike($cmds, qr/^sub _cmd_ping \{/m,
        'IV-J does not broaden into ping/uptime');

    $assert->like($party, qr/^sub _cmd_eval \{/m,
        '.eval remains in Partyline after IV-J');
    $assert->unlike($cmds, qr/^sub _cmd_eval \{/m,
        'IV-J does not broaden into .eval');

    $assert->unlike($cmds, qr/^sub _handle_line \{/m,
        'dispatcher responsibility is not duplicated in Commands.pm');
    $assert->unlike($cmds, qr/^sub _do_login \{/m,
        'authentication responsibility is not duplicated in Commands.pm');
};
