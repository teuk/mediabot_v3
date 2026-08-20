# t/cases/864_mb678_partyline_dispatcher_extraction.t
# =============================================================================
# MB678-III: Partyline dispatcher extraction contract.
# =============================================================================
use strict;
use warnings;
use File::Spec;

sub _slurp_864 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $party = _slurp_864(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $disp  = _slurp_864(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Dispatcher.pm'));
    my $sess  = _slurp_864(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'SessionAuth.pm'));
    my $trans = _slurp_864(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Transport.pm'));

    $assert->like($party, qr/use Mediabot::Partyline::Dispatcher qw\(/,
        'Partyline imports the extracted dispatcher API');
    $assert->like($disp, qr/^package Mediabot::Partyline::Dispatcher;/m,
        'dispatcher module has its dedicated package');
    $assert->like($disp, qr/MB678-III: authenticated\/pre-auth line state machine and command dispatcher/,
        'MB678-III dispatcher marker is present');

    my $in_parent = () = $party =~ /^sub\s+_handle_line\s*\{/mg;
    my $in_disp   = () = $disp  =~ /^sub\s+_handle_line\s*\{/mg;
    my $in_sess   = () = $sess  =~ /^sub\s+_handle_line\s*\{/mg;
    my $in_trans  = () = $trans =~ /^sub\s+_handle_line\s*\{/mg;

    $assert->is($in_parent, 0, '_handle_line implementation left Partyline.pm');
    $assert->is($in_disp,   1, '_handle_line implemented exactly once in Dispatcher.pm');
    $assert->is($in_sess,   0, '_handle_line is not implemented in SessionAuth.pm');
    $assert->is($in_trans,  0, '_handle_line is not implemented in Transport.pm');
    $assert->like($party, qr/^\s*_handle_line\s*$/m,
        '_handle_line remains imported into Partyline');

    $assert->like($disp, qr/Exempted during authentication/,
        'dispatcher keeps pre-auth rate-limit exemption');
    $assert->like($disp, qr/Rate limit exceeded\. Slow down\./,
        'dispatcher keeps authenticated rate limiting');
    $assert->like($disp, qr/# ---- Authenticated : dispatch commands/,
        'dispatcher owns authenticated command routing');
    $assert->like($disp, qr/Unknown command\. Type \.help for available commands\./,
        'dispatcher keeps unknown-command fallback');
    $assert->like($disp, qr/->_do_login\(/,
        'dispatcher still delegates authentication through historical methods');
    $assert->like($disp, qr/->_cmd_help\(/,
        'dispatcher still delegates command implementation through historical methods');

    $assert->like($party, qr/^sub _cmd_help \{/m,
        'command implementations remain in Partyline during MB678-III');
    $assert->like($party, qr/^sub _runtime_status_payload \{/m,
        'runtime status remains in Partyline during MB678-III');

    my $party_lines = () = $party =~ /\n/g;
    $assert->ok($party_lines < 5100,
        'Partyline monolith is materially smaller after dispatcher extraction');
};
