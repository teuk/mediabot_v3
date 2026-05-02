# t/cases/11_dcc_parser.t
# =============================================================================
#  Unit tests for Mediabot::DCC pure parser helpers
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::DCC qw(
    strip_ctcp_delimiters
    parse_ctcp_payload
    parse_dcc_payload
    parse_dcc_chat_payload
    ip_int_to_ipv4
);

return sub {
    my ($assert) = @_;

    # -------------------------------------------------------------------------
    # strip_ctcp_delimiters()
    # -------------------------------------------------------------------------
    $assert->is(strip_ctcp_delimiters("\x01CHAT\x01"), 'CHAT',
        'strip_ctcp_delimiters: raw CTCP CHAT');

    $assert->is(strip_ctcp_delimiters("  \x01CHAT\x01  "), 'CHAT',
        'strip_ctcp_delimiters: trims whitespace');

    $assert->is(strip_ctcp_delimiters(undef), '',
        'strip_ctcp_delimiters: undef -> empty string');

    # -------------------------------------------------------------------------
    # parse_ctcp_payload(): Eggdrop-style CTCP CHAT
    # -------------------------------------------------------------------------
    {
        my $r = parse_ctcp_payload("\x01CHAT\x01");
        $assert->is($r->{type}, 'ctcp_chat',
            'parse_ctcp_payload: raw CTCP CHAT');
    }

    {
        my $r = parse_ctcp_payload("CHAT");
        $assert->is($r->{type}, 'ctcp_chat',
            'parse_ctcp_payload: stripped CTCP CHAT');
    }

    # -------------------------------------------------------------------------
    # parse_ctcp_payload(): raw CTCP DCC CHAT active
    # -------------------------------------------------------------------------
    {
        my $r = parse_ctcp_payload("\x01DCC CHAT chat 1383695523 1024\x01");

        $assert->is($r->{type}, 'dcc_chat',
            'parse_ctcp_payload: raw CTCP DCC CHAT active type');

        $assert->is($r->{mode}, 'active',
            'parse_ctcp_payload: raw CTCP DCC CHAT active mode');

        $assert->is($r->{ip_int}, '1383695523',
            'parse_ctcp_payload: raw CTCP DCC CHAT active ip_int');

        $assert->is($r->{port}, '1024',
            'parse_ctcp_payload: raw CTCP DCC CHAT active port');

        $assert->ok(!defined $r->{token},
            'parse_ctcp_payload: raw CTCP DCC CHAT active no token');

        $assert->is($r->{ctcp}, 1,
            'parse_ctcp_payload: raw CTCP DCC CHAT active ctcp flag');
    }

    # -------------------------------------------------------------------------
    # parse_ctcp_payload(): raw CTCP DCC CHAT passive/token
    # -------------------------------------------------------------------------
    {
        my $r = parse_ctcp_payload("\x01DCC CHAT chat 0 0 123456\x01");

        $assert->is($r->{type}, 'dcc_chat',
            'parse_ctcp_payload: raw CTCP DCC CHAT passive type');

        $assert->is($r->{mode}, 'passive',
            'parse_ctcp_payload: raw CTCP DCC CHAT passive mode');

        $assert->is($r->{ip_int}, '0',
            'parse_ctcp_payload: raw CTCP DCC CHAT passive ip_int');

        $assert->is($r->{port}, '0',
            'parse_ctcp_payload: raw CTCP DCC CHAT passive port');

        $assert->is($r->{token}, '123456',
            'parse_ctcp_payload: raw CTCP DCC CHAT passive token');
    }

    # -------------------------------------------------------------------------
    # parse_ctcp_payload(): stripped DCC CHAT
    # -------------------------------------------------------------------------
    {
        my $r = parse_ctcp_payload("CHAT chat 1383695523 1024");

        $assert->is($r->{type}, 'dcc_chat',
            'parse_ctcp_payload: stripped DCC CHAT active type');

        $assert->is($r->{mode}, 'active',
            'parse_ctcp_payload: stripped DCC CHAT active mode');

        $assert->is($r->{ctcp}, 0,
            'parse_ctcp_payload: stripped DCC CHAT active ctcp flag');
    }

    # -------------------------------------------------------------------------
    # parse_dcc_chat_payload()
    # -------------------------------------------------------------------------
    {
        my $r = parse_dcc_chat_payload("CHAT chat 1383695523 1024");

        $assert->is($r->{type}, 'dcc_chat',
            'parse_dcc_chat_payload: active type');

        $assert->is($r->{mode}, 'active',
            'parse_dcc_chat_payload: active mode');
    }

    {
        my $r = parse_dcc_chat_payload("CHAT chat 0 0 9999");

        $assert->is($r->{type}, 'dcc_chat',
            'parse_dcc_chat_payload: passive type');

        $assert->is($r->{mode}, 'passive',
            'parse_dcc_chat_payload: passive mode');

        $assert->is($r->{token}, '9999',
            'parse_dcc_chat_payload: passive token');
    }

    {
        my $r = parse_dcc_chat_payload("DCC CHAT chat 1383695523 1024");

        $assert->is($r->{type}, 'invalid',
            'parse_dcc_chat_payload: leading DCC is invalid here');
    }

    {
        my $r = parse_dcc_payload("DCC CHAT chat 1383695523 1024");

        $assert->is($r->{type}, 'dcc_chat',
            'parse_dcc_payload: leading DCC accepted');

        $assert->is($r->{mode}, 'active',
            'parse_dcc_payload: active mode');

        $assert->is($r->{ip_int}, '1383695523',
            'parse_dcc_payload: active ip_int');

        $assert->is($r->{port}, '1024',
            'parse_dcc_payload: active port');
    }

    {
        my $r = parse_dcc_payload("\x01DCC CHAT chat 0 0 123456\x01");

        $assert->is($r->{type}, 'dcc_chat',
            'parse_dcc_payload: raw CTCP passive accepted');

        $assert->is($r->{mode}, 'passive',
            'parse_dcc_payload: passive mode');

        $assert->is($r->{token}, '123456',
            'parse_dcc_payload: passive token');
    }

    {
        my $r = parse_ctcp_payload("\x01DCC CHAT chat nope 1024\x01");

        $assert->is($r->{type}, 'private_command',
            'parse_ctcp_payload: malformed DCC does not become dcc_chat');
    }

    # -------------------------------------------------------------------------
    # Regression: /dcc chat must not become private command "dcc"
    # -------------------------------------------------------------------------
    {
        my $r = parse_ctcp_payload("\x01DCC CHAT chat 1383695523 1024\x01");

        $assert->ok($r->{type} ne 'private_command',
            'regression: raw /dcc chat does not become private command');
    }

    # -------------------------------------------------------------------------
    # ip_int_to_ipv4()
    # -------------------------------------------------------------------------
    $assert->is(ip_int_to_ipv4(0), '0.0.0.0',
        'ip_int_to_ipv4: zero');

    $assert->is(ip_int_to_ipv4(4294967295), '255.255.255.255',
        'ip_int_to_ipv4: max unsigned 32-bit');

    $assert->is(ip_int_to_ipv4(1383695523), '82.121.132.163',
        'ip_int_to_ipv4: known DCC sample');

    $assert->ok(!defined ip_int_to_ipv4('abc'),
        'ip_int_to_ipv4: invalid text');

    $assert->ok(!defined ip_int_to_ipv4(4294967296),
        'ip_int_to_ipv4: rejects > 32-bit');
};
