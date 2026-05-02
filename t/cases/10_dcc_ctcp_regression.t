# t/cases/10_dcc_ctcp_regression.t
# =============================================================================
#  Tests de non-régression DCC / CTCP raw
#
#  But :
#    - ne plus casser /dcc chat <botnick>
#    - ne plus casser /ctcp <botnick> CHAT
#    - vérifier que le handler raw DCC CHAT existe avant le parser privé
#
#  Contexte :
#    Certains clients livrent /dcc chat <botnick> sous forme :
#      \x01DCC CHAT chat <ip_int> <port>\x01
#
#    Si ce payload n'est pas intercepté avant le parser privé, Mediabot voit
#    une commande privée "dcc" et loggue :
#      Private command 'dcc' not found
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _parse_ctcp_payload_like_mediabot {
    my ($what) = @_;

    return { type => 'none' } unless defined $what;

    my $payload = $what;
    $payload =~ s/^\x01//;
    $payload =~ s/\x01$//;
    $payload =~ s/^\s+|\s+$//g;

    if ($payload =~ /^DCC\s+CHAT\s+chat\s+(\d+)\s+(\d+)(?:\s+(\d+))?\s*$/i) {
        return {
            type   => 'raw_dcc_chat',
            ip_int => $1,
            port   => $2,
            token  => $3,
        };
    }

    if ($payload =~ /^CHAT$/i) {
        return {
            type => 'raw_ctcp_chat',
        };
    }

    if ($payload =~ /^CHAT\s+chat\s+(\d+)\s+(\d+)(?:\s+(\d+))?\s*$/i) {
        return {
            type   => 'stripped_dcc_chat',
            ip_int => $1,
            port   => $2,
            token  => $3,
        };
    }

    return { type => 'private_command' };
}

return sub {
    my ($assert) = @_;

    my $mediabot_pl = File::Spec->catfile('.', 'mediabot.pl');
    my $src = _slurp($mediabot_pl);

    # -------------------------------------------------------------------------
    # 1. Static guard: raw CTCP/DCC handlers exist
    # -------------------------------------------------------------------------
    $assert->ok(
        $src =~ /Raw CTCP DCC CHAT:/,
        'mediabot.pl contains Raw CTCP DCC CHAT block'
    );

    $assert->ok(
        $src =~ /DCC CHAT request from \$who via raw CTCP payload ip=\$ip_int port=\$port/,
        'mediabot.pl logs raw DCC CHAT payload before private parser'
    );

    $assert->ok(
        $src =~ /_handle_dcc_chat_request\(\$message,\s*\$who,\s*\$ip_int,\s*\$port,\s*\$token\)/,
        'mediabot.pl dispatches raw DCC CHAT to _handle_dcc_chat_request'
    );

    $assert->ok(
        $src =~ /CTCP CHAT request from \$who via raw CTCP payload/,
        'mediabot.pl still handles raw CTCP CHAT'
    );

    $assert->ok(
        $src =~ /_handle_ctcp_chat_request\(\$message,\s*\$who\)/,
        'mediabot.pl dispatches raw CTCP CHAT to _handle_ctcp_chat_request'
    );

    # -------------------------------------------------------------------------
    # 2. Static order guard: raw handlers must appear before private parser
    # -------------------------------------------------------------------------
    my $pos_raw_dcc = index($src, 'Raw CTCP DCC CHAT:');
    my $pos_private_log = index($src, 'sCommands = $sCommand');

    $assert->ok($pos_raw_dcc >= 0, 'order: raw DCC block found');
    $assert->ok($pos_private_log >= 0, 'order: private command log found');

    # The command split may happen earlier to prepare variables.
    # The important regression guard is that raw DCC handling happens before
    # the private command parser/log path can treat it as command "dcc".
    $assert->ok(
        $pos_raw_dcc >= 0 && $pos_private_log >= 0 && $pos_raw_dcc < $pos_private_log,
        'order: raw DCC block is before sCommands private parser log'
    );

    # -------------------------------------------------------------------------
    # 3. Behavioral parser regression samples
    # -------------------------------------------------------------------------
    {
        my $r = _parse_ctcp_payload_like_mediabot("\x01CHAT\x01");
        $assert->is($r->{type}, 'raw_ctcp_chat',
            'parse: raw CTCP CHAT payload');
    }

    {
        my $r = _parse_ctcp_payload_like_mediabot("\x01DCC CHAT chat 1383695523 1024\x01");
        $assert->is($r->{type}, 'raw_dcc_chat',
            'parse: raw DCC CHAT active payload');
        $assert->is($r->{ip_int}, '1383695523',
            'parse: raw DCC CHAT active ip_int');
        $assert->is($r->{port}, '1024',
            'parse: raw DCC CHAT active port');
        $assert->ok(!defined $r->{token},
            'parse: raw DCC CHAT active has no token');
    }

    {
        my $r = _parse_ctcp_payload_like_mediabot("\x01DCC CHAT chat 0 0 123456\x01");
        $assert->is($r->{type}, 'raw_dcc_chat',
            'parse: raw DCC CHAT passive payload');
        $assert->is($r->{ip_int}, '0',
            'parse: raw DCC CHAT passive ip_int');
        $assert->is($r->{port}, '0',
            'parse: raw DCC CHAT passive port');
        $assert->is($r->{token}, '123456',
            'parse: raw DCC CHAT passive token');
    }

    {
        my $r = _parse_ctcp_payload_like_mediabot("CHAT chat 1383695523 1024");
        $assert->is($r->{type}, 'stripped_dcc_chat',
            'parse: stripped DCC CHAT active payload');
    }

    {
        my $r = _parse_ctcp_payload_like_mediabot("DCC CHAT chat nope 1024");
        $assert->is($r->{type}, 'private_command',
            'parse: malformed raw DCC CHAT is not accepted');
    }

    # -------------------------------------------------------------------------
    # 4. Regression intent:
    #    The first word of raw DCC payload is "DCC", but it must never reach the
    #    private command parser as command "dcc".
    # -------------------------------------------------------------------------
    {
        my $r = _parse_ctcp_payload_like_mediabot("\x01DCC CHAT chat 1383695523 1024\x01");
        $assert->ok($r->{type} ne 'private_command',
            'regression: raw /dcc chat does not become private command dcc');
    }
};
