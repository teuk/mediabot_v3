# t/cases/862_mb678_partyline_transport_extraction.t
# =============================================================================
# MB678: Partyline transport extraction contract.
# =============================================================================
use strict;
use warnings;
use File::Spec;

sub _slurp_862 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $party = _slurp_862(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $trans = _slurp_862(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Transport.pm'));
    my $disp  = _slurp_862(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Dispatcher.pm'));

    $assert->like($party, qr/use Mediabot::Partyline::Transport qw\(/,
        'Partyline imports the extracted transport API');
    $assert->like($trans, qr/^package Mediabot::Partyline::Transport;/m,
        'transport module has its dedicated package');
    $assert->like($trans, qr/mb678: transport extraction/,
        'MB678 extraction marker is present');

    my @methods = qw(
        accept_dcc_chat _resolve_dcc_public_ip _dcc_listen_port
        _dcc_offer_key _dcc_pending_offer_for_nick _dcc_offer_register
        _dcc_offer_remove _dcc_offer_mark_connected _dcc_offers_snapshot
        offer_dcc_chat _dcc_token_hint accept_dcc_chat_passive
        _extract_input_lines _reject_oversized_input _dispatch_line_safely
        _report_operation_error _init_dcc_session _peer_ip_from_handle
        _start_listener
    );

    for my $name (@methods) {
        my $in_parent = () = $party =~ /^sub\s+\Q$name\E\s*\{/mg;
        my $in_trans  = () = $trans =~ /^sub\s+\Q$name\E\s*\{/mg;

        $assert->is($in_parent, 0, "$name implementation left Partyline.pm");
        $assert->is($in_trans, 1, "$name implemented exactly once in Transport.pm");
        $assert->like($party, qr/^\s*\Q$name\E\s*$/m,
            "$name remains imported into Partyline");
    }

    $assert->like($party, qr/sub new \{.*?\$self->_start_listener;/s,
        'constructor still starts the historical listener method');
    $assert->unlike($trans, qr/^sub _handle_line \{/m,
        'command dispatch is not part of the transport module');
    $assert->like($disp, qr/^sub _handle_line \{/m,
        'command dispatch remains available in the dedicated dispatcher module');
    $assert->unlike($trans, qr/^sub _do_login \{/m,
        'authentication is not part of the transport module');
    $assert->unlike($trans, qr/^sub _close_session \{/m,
        'session lifecycle is not part of the transport module');
    $assert->like($party, qr/use constant MAX_PARTYLINE_LINE_BYTES => 4 \* 1024;/,
        'historical public input-bound constant remains in Partyline');
    $assert->like(
        $trans,
        qr/sub MAX_PARTYLINE_LINE_BYTES \{ Mediabot::Partyline::MAX_PARTYLINE_LINE_BYTES\(\) \}/,
        'transport resolves the input-bound constant through the historical package'
    );

    my $party_lines = () = $party =~ /\n/g;
    $assert->ok($party_lines < 6200,
        'Partyline monolith is materially smaller after transport extraction');
};
