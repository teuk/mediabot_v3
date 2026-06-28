# t/cases/560_mb340_partyline_peer_ip_ipv6.t
# =============================================================================
# mb340 — Capture de l'IP distante du partyline en IPv4 ET IPv6.
#
# La création de session telnet ne décodait que AF_INET (inet_ntoa) ; une
# connexion IPv6 retombait sur 'unknown' (visible dans .whom et les logs).
# mb340 factorise la résolution dans _peer_ip_from_handle, qui gère désormais
# AF_INET et AF_INET6 (défensivement : symboles IPv6 pleinement qualifiés +
# gardes de disponibilité + eval, donc fallback propre sur 'unknown').
#
# Ce test exécute le VRAI helper (extrait du source) avec un handle factice
# renvoyant un sockaddr IPv4, IPv6, ou undef.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;
use Socket qw(pack_sockaddr_in inet_aton);

{
    package T560::Handle;
    sub new { my ($c, $pn) = @_; bless { pn => $pn }, $c }
    sub peername { return $_[0]->{pn} }
}

sub _slurp_560 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_560 {
    my ($src, $name) = @_;
    return undef unless $src =~ /(sub\s+\Q$name\E\s*\{)/;
    my $start = $-[0];
    my $i     = index($src, '{', $start);
    my $depth = 0;
    for (my $p = $i; $p < length($src); $p++) {
        my $c = substr($src, $p, 1);
        $depth++ if $c eq '{';
        $depth-- if $c eq '}';
        return substr($src, $start, $p - $start + 1) if $depth == 0;
    }
    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_560(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $sub_src = _extract_sub_560($src, '_peer_ip_from_handle');
    $assert->ok(defined $sub_src && $sub_src ne '', '_peer_ip_from_handle extrait du source');

    # Compile le vrai helper dans un package de test, avec les imports Socket
    # dont il dépend (les symboles IPv6 restent pleinement qualifiés).
    my $resolver;
    {
        no strict; no warnings;
        $resolver = eval qq{
            package T560::PL;
            use Socket qw(unpack_sockaddr_in sockaddr_family inet_ntoa AF_INET);
            $sub_src
            \\&T560::PL::_peer_ip_from_handle;
        };
    }
    $assert->ok(ref($resolver) eq 'CODE', 'helper compilé en isolation') or return;

    # IPv4
    my $v4 = pack_sockaddr_in(6667, inet_aton('203.0.113.42'));
    $assert->is($resolver->(T560::Handle->new($v4)), '203.0.113.42', 'IPv4 résolu en notation pointée');

    # IPv6 (si Socket le supporte sur cette plateforme)
    if (defined(&Socket::AF_INET6)
        && defined(&Socket::pack_sockaddr_in6)
        && defined(&Socket::inet_pton)) {
        my $v6 = Socket::pack_sockaddr_in6(6667, Socket::inet_pton(Socket::AF_INET6(), '2001:db8::1'));
        my $got = $resolver->(T560::Handle->new($v6));
        $assert->is($got, '2001:db8::1', 'IPv6 résolu en notation colon');
    }
    else {
        $assert->ok(1, 'IPv6 non supporté par Socket ici — fallback couvert ci-dessous');
    }

    # Handle absent -> fallback 'unknown'
    $assert->is($resolver->(undef), 'unknown', 'handle absent -> unknown (fallback)');
    # peername undef -> fallback 'unknown'
    $assert->is($resolver->(T560::Handle->new(undef)), 'unknown', 'peername undef -> unknown');

    # Scan de source : la branche IPv6 est bien présente.
    $assert->like($sub_src, qr/Socket::AF_INET6/, 'le helper gère AF_INET6');
    $assert->like($sub_src, qr/mb340-B1/, 'tag mb340-B1 présent');
};
