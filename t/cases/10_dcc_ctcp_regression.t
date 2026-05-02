# t/cases/10_dcc_ctcp_regression.t
# =============================================================================
#  DCC / CTCP runtime regression tests
#
#  This test protects the mediabot.pl integration path.
#
#  The pure parser itself is tested in:
#    t/cases/11_dcc_parser.t
#
#  Here we verify that mediabot.pl is wired to Mediabot::DCC before the private
#  command parser can treat raw DCC CHAT as a private command named "dcc".
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;
use Mediabot::DCC qw(parse_ctcp_payload);

sub _slurp {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $mediabot_pl = File::Spec->catfile('.', 'mediabot.pl');
    my $src = _slurp($mediabot_pl);

    # -------------------------------------------------------------------------
    # 1. mediabot.pl must use the shared parser module
    # -------------------------------------------------------------------------
    my $has_import = ($src =~ /use\s+Mediabot::DCC\s+qw\([^)]*\bparse_ctcp_payload\b[^)]*\);/) ? 1 : 0;
    my $has_parse_call = ($src =~ /my\s+\$dcc_parse\s*=\s*parse_ctcp_payload\(\$what\);/) ? 1 : 0;
    my $has_ctcp_log = ($src =~ /CTCP CHAT request from \$who via Mediabot::DCC parser/) ? 1 : 0;
    my $has_dcc_log = ($src =~ /DCC CHAT request from \$who via Mediabot::DCC parser ip=\$ip_int port=\$port/) ? 1 : 0;

    $assert->is($has_import, 1,
        'mediabot.pl imports Mediabot::DCC parse_ctcp_payload');

    $assert->is($has_parse_call, 1,
        'mediabot.pl parses CTCP/DCC payload through Mediabot::DCC');

    $assert->is($has_ctcp_log, 1,
        'mediabot.pl logs CTCP CHAT through Mediabot::DCC parser');

    $assert->is($has_dcc_log, 1,
        'mediabot.pl logs DCC CHAT through Mediabot::DCC parser');

    $assert->ok(
        $src =~ /_handle_ctcp_chat_request\(\$message,\s*\$who\)/,
        'mediabot.pl dispatches CTCP CHAT to _handle_ctcp_chat_request'
    );

    $assert->ok(
        $src =~ /_handle_dcc_chat_request\(\$message,\s*\$who,\s*\$ip_int,\s*\$port,\s*\$token\)/,
        'mediabot.pl dispatches DCC CHAT to _handle_dcc_chat_request'
    );

    my $has_ctcp_dcc_handler_parse = ($src =~ /sub\s+on_message_ctcp_DCC\s*\{[\s\S]*?parse_dcc_payload\(\$args\)/) ? 1 : 0;
    my $has_ctcp_dcc_handler_predicate = ($src =~ /sub\s+on_message_ctcp_DCC\s*\{[\s\S]*?is_dcc_chat\(\$dcc_parse\)/) ? 1 : 0;
    my $has_ctcp_dcc_handler_log = ($src =~ /CTCP DCC CHAT request from \$who via Mediabot::DCC parser/) ? 1 : 0;
    my $has_dcc_debug_hints = ($src =~ /DCC_DEBUG_HINTS/) ? 1 : 0;

    $assert->is($has_ctcp_dcc_handler_parse, 1,
        'on_message_ctcp_DCC uses parse_dcc_payload');

    $assert->is($has_ctcp_dcc_handler_predicate, 1,
        'on_message_ctcp_DCC uses is_dcc_chat');

    $assert->is($has_ctcp_dcc_handler_log, 1,
        'on_message_ctcp_DCC logs Mediabot::DCC parser path');

    $assert->is($has_dcc_debug_hints, 1,
        'CTCP DCC raw debug is gated by DCC_DEBUG_HINTS');

    # -------------------------------------------------------------------------
    # 2. Parser module path must run before private command logging.
    # -------------------------------------------------------------------------
    my $pos_parser = index($src, 'parse_ctcp_payload($what)');
    my $pos_private_log = index($src, 'sCommands = $sCommand');

    $assert->ok($pos_parser >= 0, 'order: Mediabot::DCC parser call found');
    $assert->ok($pos_private_log >= 0, 'order: private command log found');

    $assert->ok(
        $pos_parser >= 0 && $pos_private_log >= 0 && $pos_parser < $pos_private_log,
        'order: Mediabot::DCC parser path is before private command parser log'
    );

    # -------------------------------------------------------------------------
    # 3. Actual parser behavior for the historically fragile cases.
    # -------------------------------------------------------------------------
    {
        my $r = parse_ctcp_payload("\x01CHAT\x01");

        $assert->is($r->{type}, 'ctcp_chat',
            'parser: raw CTCP CHAT payload');
    }

    {
        my $r = parse_ctcp_payload("\x01DCC CHAT chat 1383695523 1024\x01");

        $assert->is($r->{type}, 'dcc_chat',
            'parser: raw DCC CHAT active payload');

        $assert->is($r->{mode}, 'active',
            'parser: raw DCC CHAT active mode');

        $assert->is($r->{ip_int}, '1383695523',
            'parser: raw DCC CHAT active ip_int');

        $assert->is($r->{port}, '1024',
            'parser: raw DCC CHAT active port');

        $assert->ok(!defined $r->{token},
            'parser: raw DCC CHAT active has no token');
    }

    {
        my $r = parse_ctcp_payload("\x01DCC CHAT chat 0 0 123456\x01");

        $assert->is($r->{type}, 'dcc_chat',
            'parser: raw DCC CHAT passive payload');

        $assert->is($r->{mode}, 'passive',
            'parser: raw DCC CHAT passive mode');

        $assert->is($r->{ip_int}, '0',
            'parser: raw DCC CHAT passive ip_int');

        $assert->is($r->{port}, '0',
            'parser: raw DCC CHAT passive port');

        $assert->is($r->{token}, '123456',
            'parser: raw DCC CHAT passive token');
    }

    {
        my $r = parse_ctcp_payload("CHAT chat 1383695523 1024");

        $assert->is($r->{type}, 'dcc_chat',
            'parser: stripped DCC CHAT active payload');
    }

    {
        my $r = parse_ctcp_payload("\x01DCC CHAT chat nope 1024\x01");

        $assert->is($r->{type}, 'private_command',
            'parser: malformed raw DCC CHAT is not accepted as DCC CHAT');
    }

    # -------------------------------------------------------------------------
    # 4. Regression intent:
    #    The first word of raw DCC payload is "DCC", but it must never reach the
    #    private command parser as command "dcc".
    # -------------------------------------------------------------------------
    {
        my $r = parse_ctcp_payload("\x01DCC CHAT chat 1383695523 1024\x01");

        $assert->ok($r->{type} ne 'private_command',
            'regression: raw /dcc chat does not become private command dcc');
    }
};
