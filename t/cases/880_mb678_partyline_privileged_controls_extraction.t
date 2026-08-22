# t/cases/880_mb678_partyline_privileged_controls_extraction.t
# =============================================================================
# MB678-IV-O: privileged Partyline controls extraction.
#
# .eval and .die are deliberately isolated from ordinary commands because they
# can execute arbitrary Perl or terminate the bot process.  The historical
# Mediabot::Partyline method surface and dispatcher routing must not change.
# =============================================================================
use strict;
use warnings;
use File::Spec;

sub _slurp_880 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $party = _slurp_880(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $priv  = _slurp_880(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Privileged.pm'));
    my $cmds  = _slurp_880(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Commands.pm'));
    my $disp  = _slurp_880(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Dispatcher.pm'));

    $assert->like($priv, qr/MB678-IV-O: privileged Partyline control extraction/,
        'IV-O privileged-control extraction marker is present');

    for my $name (qw(_cmd_eval _cmd_die)) {
        my $in_parent = () = $party =~ /^sub\s+\Q$name\E\s*\{/mg;
        my $in_priv   = () = $priv  =~ /^sub\s+\Q$name\E\s*\{/mg;
        my $in_cmds   = () = $cmds  =~ /^sub\s+\Q$name\E\s*\{/mg;

        $assert->is($in_parent, 0, "$name implementation left Partyline.pm");
        $assert->is($in_priv, 1, "$name implemented exactly once in Privileged.pm");
        $assert->is($in_cmds, 0, "$name is not duplicated in Commands.pm");
        $assert->like($party, qr/^\s*\Q$name\E\s*$/m,
            "$name remains imported into Partyline");
        $assert->like($disp, qr/->\Q$name\E\(/,
            "dispatcher still routes through historical $name surface");
    }

    $assert->like($priv, qr/Access denied: \.eval requires Owner level\./,
        '.eval keeps Owner-only authorization');
    $assert->like($priv, qr/get\('main\.PARTYLINE_EVAL_ENABLED'\)/,
        '.eval keeps explicit configuration gate');
    $assert->like($priv, qr/Type the same \.eval command again within 30 seconds to execute\./,
        '.eval keeps one-step confirmation');
    $assert->like($priv, qr/get\('main\.PARTYLINE_EVAL_TIMEOUT_SECONDS'\)/,
        '.eval keeps configurable bounded timeout');
    $assert->like($priv, qr/waitpid\(\$pid, WNOHANG\)/,
        '.eval keeps non-blocking child reaping');
    $assert->unlike($priv, qr/waitpid\(\$pid,\s*0\)/,
        '.eval does not introduce blocking child reaping');
    $assert->unlike($priv, qr/\busleep\s*\(/,
        '.eval keeps asynchronous watchdog timing');
    $assert->like($priv, qr/kill 'TERM', \$pid/,
        '.eval watchdog keeps TERM stage');
    $assert->like($priv, qr/kill 'KILL', \$pid/,
        '.eval watchdog keeps KILL escalation');
    $assert->like($priv, qr/\@\{ \$eval_ctx->\{lines\} \} < 20/,
        '.eval output remains capped at twenty lines');

    $assert->like($priv, qr/Access denied: \.die requires Owner level\./,
        '.die keeps Owner-only authorization');
    $assert->like($priv, qr/setShutdownExitCode\(\$bot->getNoRestartExitCode\(\)\)/,
        '.die keeps intentional no-restart exit contract');
    $assert->like($priv, qr/\$self->_close_session\(\$id\)/,
        '.die keeps Partyline session shutdown');
    $assert->like($priv, qr/\$bot->\{Quit\} = 1/,
        '.die keeps final bot shutdown flag');
    $assert->like($priv, qr/send_message\("QUIT", undef, \$msg\)/,
        '.die keeps IRC QUIT path');

    for my $core (qw(new get_port _runtime_status_path _runtime_status_payload _write_runtime_status)) {
        $assert->like($party, qr/^sub\s+\Q$core\E\s*\{/m,
            "$core remains in Partyline core");
        $assert->unlike($priv, qr/^sub\s+\Q$core\E\s*\{/m,
            "$core is not duplicated in Privileged.pm");
        $assert->unlike($cmds, qr/^sub\s+\Q$core\E\s*\{/m,
            "$core is not duplicated in Commands.pm");
    }

    my @parent_subs = ($party =~ /^sub\s+(\w+)\s*\{/mg);
    $assert->is(
        join(',', @parent_subs),
        join(',', qw(new get_port _runtime_status_path _runtime_status_payload _write_runtime_status)),
        'Partyline.pm now contains only the five core implementations'
    );
};
