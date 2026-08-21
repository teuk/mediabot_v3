# t/cases/863_mb678_partyline_session_auth_extraction.t
# =============================================================================
# MB678-II: Partyline session/auth extraction contract.
# =============================================================================
use strict;
use warnings;
use File::Spec;

sub _slurp_863 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $party = _slurp_863(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $sess  = _slurp_863(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'SessionAuth.pm'));
    my $trans = _slurp_863(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Transport.pm'));
    my $disp  = _slurp_863(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Dispatcher.pm'));
    my $cmds  = _slurp_863(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Commands.pm'));

    $assert->like($party, qr/use Mediabot::Partyline::SessionAuth qw\(/,
        'Partyline imports the extracted session/auth API');
    $assert->like($sess, qr/^package Mediabot::Partyline::SessionAuth;/m,
        'session/auth module has its dedicated package');
    $assert->like($sess, qr/mb678-II: session\/auth extraction/,
        'MB678-II extraction marker is present');

    my @methods = qw(
        _cancel_auth_timeout _close_session _reverse_dns_timeout
        _schedule_reverse_dns_lookup _display_nick _broadcast _broadcast_chat
        _telnet_echo_off _telnet_echo_on _strip_telnet_iac
        _pl_bf_blocked _pl_bf_record _pl_bf_clear _do_login
    );

    for my $name (@methods) {
        my $in_parent = () = $party =~ /^sub\s+\Q$name\E\s*\{/mg;
        my $in_sess   = () = $sess  =~ /^sub\s+\Q$name\E\s*\{/mg;
        my $in_trans  = () = $trans =~ /^sub\s+\Q$name\E\s*\{/mg;

        $assert->is($in_parent, 0, "$name implementation left Partyline.pm");
        $assert->is($in_sess, 1, "$name implemented exactly once in SessionAuth.pm");
        $assert->is($in_trans, 0, "$name is not implemented in Transport.pm");
        $assert->like($party, qr/^\s*\Q$name\E\s*$/m,
            "$name remains imported into Partyline");
    }

    $assert->unlike($sess, qr/^sub _handle_line \{/m,
        'dispatcher is not part of SessionAuth.pm');
    $assert->like($disp, qr/^sub _handle_line \{/m,
        'line/auth/command dispatch remains available in Dispatcher.pm');
    $assert->unlike($party, qr/^sub _cmd_help \{/m,
        'later command extraction leaves _cmd_help out of Partyline.pm');
    $assert->like($cmds, qr/^sub _cmd_help \{/m,
        'later command extraction keeps _cmd_help in Commands.pm');
    $assert->like($sess, qr/PARTYLINE_LOGIN_IP_MAX_FAILURES/,
        'session/auth module owns brute-force login policy');
    $assert->like($sess, qr/verify_credentials/,
        'session/auth module still delegates credential validation to Auth');
    $assert->like($sess, qr/_schedule_reverse_dns_lookup/,
        'session/auth module owns asynchronous session identity lookup');

    my $party_lines = () = $party =~ /\n/g;
    $assert->ok($party_lines < 5500,
        'Partyline monolith is materially smaller after session/auth extraction');
};
