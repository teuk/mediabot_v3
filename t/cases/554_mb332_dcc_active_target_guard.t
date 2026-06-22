# t/cases/554_mb332_dcc_active_target_guard.t
# =============================================================================
# MB332 — active DCC CHAT must never turn the bot into an SSRF/port-scanning
# client for private, loopback, link-local or reserved networks.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;
use Mediabot::DCC qw(
    ip_int_to_ipv4
    validate_dcc_active_target
);

sub _slurp_554 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path
        or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _ip_int_554 {
    my ($ip) = @_;
    my @octet = split /\./, $ip;
    die "bad test IPv4: $ip" unless @octet == 4;

    return (($octet[0] << 24)
          | ($octet[1] << 16)
          | ($octet[2] << 8)
          |  $octet[3]);
}

sub _validate_554 {
    my ($ip, $port) = @_;
    return validate_dcc_active_target(_ip_int_554($ip), $port);
}

return sub {
    my ($assert) = @_;

    {
        my ($ok, $ip, $reason) = _validate_554('82.121.132.163', 1024);
        $assert->is($ok, 1, 'historical public DCC address is accepted');
        $assert->is($ip, '82.121.132.163', 'accepted address is canonicalized');
        $assert->is($reason, 'ok', 'accepted target returns ok reason');
    }

    {
        my ($ok, $ip, $reason) = _validate_554('8.8.8.8', 65535);
        $assert->is($ok, 1, 'public IPv4 with maximum valid port is accepted');
        $assert->is($ip, '8.8.8.8', 'second public address is preserved');
    }

    my @blocked = (
        [ '0.0.0.1',         'unspecified'     ],
        [ '10.0.0.1',        'private'         ],
        [ '100.64.0.1',      'shared_cgnat'    ],
        [ '127.0.0.1',       'loopback'        ],
        [ '169.254.1.1',     'link_local'      ],
        [ '172.16.0.1',      'private'         ],
        [ '172.31.255.255',  'private'         ],
        [ '192.0.0.1',       'ietf_protocol'   ],
        [ '192.0.2.1',       'documentation'   ],
        [ '192.168.1.1',     'private'         ],
        [ '192.88.99.1',     'deprecated_6to4' ],
        [ '198.18.0.1',      'benchmark'       ],
        [ '198.51.100.1',    'documentation'   ],
        [ '203.0.113.1',     'documentation'   ],
        [ '224.0.0.1',       'multicast'       ],
        [ '240.0.0.1',       'reserved'        ],
        [ '255.255.255.255', 'reserved'        ],
    );

    for my $case (@blocked) {
        my ($address, $expected_reason) = @$case;
        my ($ok, $ip, $reason) = _validate_554($address, 5000);

        $assert->is($ok, 0, "$address is rejected");
        $assert->is($reason, $expected_reason,
            "$address rejection reason is $expected_reason");
    }

    for my $case (
        [ '8.8.8.8', 0,     'invalid_port' ],
        [ '8.8.8.8', 80,    'invalid_port' ],
        [ '8.8.8.8', 65536, 'invalid_port' ],
        [ '8.8.8.8', 'abc', 'invalid_port' ],
    ) {
        my ($address, $port, $expected_reason) = @$case;
        my ($ok, undef, $reason) = _validate_554($address, $port);

        $assert->is($ok, 0, "port '$port' is rejected");
        $assert->is($reason, $expected_reason,
            "port '$port' returns invalid_port");
    }

    {
        my ($ok, $ip, $reason)
            = validate_dcc_active_target('4294967296', 5000);
        $assert->is($ok, 0, 'IPv4 integer above 32-bit range is rejected');
        $assert->ok(!defined($ip), 'out-of-range IPv4 has no dotted address');
        $assert->is($reason, 'invalid_ipv4_integer',
            'out-of-range IPv4 returns explicit reason');
    }

    {
        my ($ok, $ip, $reason)
            = validate_dcc_active_target('not-a-number', 5000);
        $assert->is($ok, 0, 'non-numeric IPv4 integer is rejected');
        $assert->ok(!defined($ip), 'invalid IPv4 text has no dotted address');
        $assert->is($reason, 'invalid_ipv4_integer',
            'invalid IPv4 text returns explicit reason');
    }

    my $dcc = _slurp_554(
        File::Spec->catfile('.', 'Mediabot', 'DCC.pm')
    );
    my $main = _slurp_554(
        File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm')
    );
    my $partyline = _slurp_554(
        File::Spec->catfile('.', 'Mediabot', 'Partyline.pm')
    );

    $assert->like(
        $dcc,
        qr/\bvalidate_dcc_active_target\b/,
        'pure DCC module exposes the central active-target validator'
    );

    $assert->like(
        $main,
        qr/use Mediabot::DCC qw\(validate_dcc_active_target\)/,
        'Mediabot runtime imports the active-target validator'
    );

    $assert->like(
        $main,
        qr/unless \(\$is_passive\).*?validate_dcc_active_target\(\$ip_int, \$port\).*?rejected active target/s,
        'runtime handler validates active targets while preserving passive DCC'
    );

    my $validator_pos = index($main, 'validate_dcc_active_target($ip_int, $port)');
    my $lookup_pos    = index($main, 'my $row = $self->_fetch_user_for_dcc($nick);',
                              $validator_pos);

    $assert->ok(
        $validator_pos >= 0 && $lookup_pos > $validator_pos,
        'unsafe destination is rejected before DB lookup and socket delegation'
    );

    $assert->like(
        $partyline,
        qr/use Mediabot::DCC qw\(validate_dcc_active_target\)/,
        'Partyline imports the validator for defense in depth'
    );

    $assert->like(
        $partyline,
        qr/sub accept_dcc_chat \{.*?validate_dcc_active_target\(\$ip_int, \$port\).*?refusing unsafe target/s,
        'network sink validates the destination before connecting'
    );

    my $sink_validator_pos
        = index($partyline, 'validate_dcc_active_target($ip_int, $port)');
    my $connect_pos = index($partyline, '$loop->connect(', $sink_validator_pos);

    $assert->ok(
        $sink_validator_pos >= 0 && $connect_pos > $sink_validator_pos,
        'Partyline validates before IO::Async opens the socket'
    );

    $assert->like(
        $main,
        qr/accept_dcc_chat_passive\(\$nick, \$token\)/,
        'passive token-based DCC flow remains available'
    );
};
