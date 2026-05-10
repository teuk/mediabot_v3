# t/cases/216_admincommands_radio_icecast_factory_regression.t
# =============================================================================
# Regression checks for AdminCommands Icecast client construction.
#
# Radio commands should all use the same helper to build Mediabot::Radio::Icecast.
# This prevents drift between radiostatus, radiomounts, listeners and song.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_216 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_216 {
    my ($src, $sub_name) = @_;

    my $re = qr/^[ \t]*sub[ \t]+\Q$sub_name\E\b[^{]*\{/m;
    return undef unless $src =~ /$re/g;

    my $start = $-[0];
    my $pos   = pos($src);
    my $depth = 1;
    my $len   = length($src);

    my $quote;
    my $escape  = 0;
    my $comment = 0;

    while ($pos < $len) {
        my $ch = substr($src, $pos, 1);

        if ($comment) {
            $comment = 0 if $ch eq "\n";
            $pos++;
            next;
        }

        if (defined $quote) {
            if ($escape) {
                $escape = 0;
                $pos++;
                next;
            }

            if ($ch eq "\\") {
                $escape = 1;
                $pos++;
                next;
            }

            if ($ch eq $quote) {
                undef $quote;
                $pos++;
                next;
            }

            $pos++;
            next;
        }

        if ($ch eq '#') {
            $comment = 1;
            $pos++;
            next;
        }

        if ($ch eq '"' || $ch eq "'") {
            $quote = $ch;
            $pos++;
            next;
        }

        if ($ch eq '{') {
            $depth++;
        }
        elsif ($ch eq '}') {
            $depth--;

            if ($depth == 0) {
                return substr($src, $start, $pos + 1 - $start);
            }
        }

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_216(
        File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm')
    );

    my $cfg    = _extract_sub_216($src, '_radio_icecast_config');
    my $client = _extract_sub_216($src, '_radio_icecast_client');

    $assert->ok(defined $cfg && $cfg ne '', '_radio_icecast_config body found');
    $assert->ok(defined $client && $client ne '', '_radio_icecast_client body found');

    $assert->like(
        $cfg // '',
        qr/RADIO_ICECAST_STATUS_BASE_URL/,
        'Icecast config helper reads status base URL'
    );

    $assert->like(
        $cfg // '',
        qr/RADIO_ICECAST_PUBLIC_BASE_URL/,
        'Icecast config helper reads public base URL'
    );

    $assert->like(
        $cfg // '',
        qr/RADIO_ICECAST_PRIMARY_MOUNT/,
        'Icecast config helper reads primary mount'
    );

    $assert->like(
        $cfg // '',
        qr/RADIO_ICECAST_TIMEOUT/,
        'Icecast config helper reads timeout'
    );

    $assert->like(
        $client // '',
        qr/Mediabot::Radio::Icecast->new\(/,
        'Icecast client helper builds the client'
    );

    $assert->like(
        $client // '',
        qr/Mediabot::External::_make_http\(timeout\s*=>\s*\$cfg->\{timeout\},\s*verify_SSL\s*=>\s*0\)/,
        'Icecast client helper uses shared HTTP factory'
    );

    my $count = () = $src =~ /Mediabot::Radio::Icecast->new\(/g;
    $assert->ok($count == 1, 'AdminCommands has exactly one Icecast->new construction');

    for my $sub (qw(radioStatus_ctx radioMounts_ctx displayRadioListeners_ctx song_ctx)) {
        my $body = _extract_sub_216($src, $sub);

        $assert->ok(defined $body && $body ne '', "$sub body found");

        $assert->like(
            $body // '',
            qr/_radio_icecast_client\(\$self\)/,
            "$sub uses centralized Icecast client helper"
        );

        $assert->unlike(
            $body // '',
            qr/Mediabot::Radio::Icecast->new\(/,
            "$sub does not construct Icecast client directly"
        );
    }
};
