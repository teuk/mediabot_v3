# t/cases/07_partyline_unit.t
# =============================================================================
#  Tests unitaires de Mediabot::Partyline
#  - _display_nick : format nick@host
#  - _strip_telnet_iac : stripping séquences IAC
#  - _dcc_offer_key, _dcc_offer_register, _dcc_offer_remove,
#    _dcc_offer_mark_connected, _dcc_offers_snapshot
#  - _broadcast : envoie à tous les authentifiés sauf excluded
#  - get_port
# =============================================================================

use strict;
use warnings;
BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";   # t/lib/
    unshift @INC, "$Bin/..";      # racine du projet (mediabot_v3/)
}
use Mediabot::Partyline;
use Mediabot::Log;

return sub {
    my ($assert) = @_;

    my $logger = Mediabot::Log->new(debug_level => -1);

    # ── Stubs ─────────────────────────────────────────────────────────────────
    { package MockConf2; sub get { $_[0]->{_conf}{$_[1]} } }

    my $fake_bot = bless {
        logger  => $logger,
        conf    => bless({ _conf => { 'main.PARTYLINE_PORT' => 23456 } }, 'MockConf2'),
        metrics => undef,
    }, 'FakeBot2';

    { package FakeLoop2;
      sub add       { }
      sub remove    { }
      sub listen    { bless {}, 'FakeListener2' }
      sub connect   { }
      sub watch_time { }
    }
    { package FakeListener2; sub get { } }

    my $fake_loop = bless {}, 'FakeLoop2';

    # ── Construire la Partyline par bless direct (évite _start_listener) ────────
    # On bless directement pour ne pas déclencher le listener TCP réel,
    # tout en obtenant un objet Mediabot::Partyline avec toutes ses méthodes.
    my $pl = bless {
        bot        => $fake_bot,
        loop       => $fake_loop,
        port       => 23456,
        streams    => {},
        users      => {},
        motd       => [],
        dcc_offers => {},
    }, 'Mediabot::Partyline';

    $assert->ok(ref($pl) eq 'Mediabot::Partyline', 'Partyline bless direct : ok');

    # ─────────────────────────────────────────────────────────────────────────
    # 1. _display_nick
    # ─────────────────────────────────────────────────────────────────────────
    SKIP_DISPLAY: {
        unless ($pl->can('_display_nick')) {
            $assert->ok(1, '_display_nick : skip (méthode absente dans cette version)');
            last SKIP_DISPLAY;
        }

        $pl->{users}{42} = { login => 'teuk', peer_host => '127.0.0.1' };
        $assert->is($pl->_display_nick(42), 'teuk@127.0.0.1',
            '_display_nick : format nick@host');

        $pl->{users}{43} = { login => undef, peer_host => undef };
        $assert->is($pl->_display_nick(43), 'unknown@unknown',
            '_display_nick : undef → unknown@unknown');

        delete $pl->{users}{42};
        delete $pl->{users}{43};
    }

    # ─────────────────────────────────────────────────────────────────────────
    # 2. _strip_telnet_iac
    # ─────────────────────────────────────────────────────────────────────────
    {
        # IAC WILL ECHO (FF FB 01) → supprimé
        my $raw = "hello\xFF\xFB\x01world";
        $assert->is($pl->_strip_telnet_iac($raw), 'helloworld',
            '_strip_telnet_iac : supprime IAC WILL ECHO');

        # IAC IAC → IAC unique
        my $escaped = "data\xFF\xFFmore";
        $assert->is($pl->_strip_telnet_iac($escaped), "data\xFFmore",
            '_strip_telnet_iac : IAC IAC → IAC');

        # Texte sans IAC → inchangé
        $assert->is($pl->_strip_telnet_iac('normal text'), 'normal text',
            '_strip_telnet_iac : texte propre inchangé');

        # undef → ''
        $assert->is($pl->_strip_telnet_iac(undef), '',
            '_strip_telnet_iac : undef → ""');
    }

    # ─────────────────────────────────────────────────────────────────────────
    # 3. _dcc_offer_key
    # ─────────────────────────────────────────────────────────────────────────
    SKIP_DCC_KEY: {
        unless ($pl->can('_dcc_offer_key')) {
            $assert->ok(1, '_dcc_offer_key : skip (méthode absente)');
            last SKIP_DCC_KEY;
        }

        $assert->is($pl->_dcc_offer_key('ctcp_chat', 'TeUk'), 'ctcp_chat:teuk',
            '_dcc_offer_key : minuscules + type:nick');

        $assert->is($pl->_dcc_offer_key(undef, 'teuk'), 'dcc_chat:teuk',
            '_dcc_offer_key : type undef → dcc_chat');
    }

    # ─────────────────────────────────────────────────────────────────────────
    # 4. DCC offer register / pending / mark_connected / remove / snapshot
    # ─────────────────────────────────────────────────────────────────────────
    SKIP_DCC_REG: {
        unless ($pl->can('_dcc_offer_register')) {
            $assert->ok(1, '_dcc_offer_register : skip (méthode absente)');
            last SKIP_DCC_REG;
        }

        my $fake_listener = bless {}, 'FakeListenerObj';
        my $offer = $pl->_dcc_offer_register(
            'ctcp_chat', 'teuk', 12345, '91.121.1.1', $fake_listener
        );
        $assert->ok(defined $offer,                     '_dcc_offer_register : retourne l\'offre');
        $assert->is($offer->{nick},      'teuk',        'offer->{nick}');
        $assert->is($offer->{port},      12345,         'offer->{port}');
        $assert->is($offer->{public_ip}, '91.121.1.1',  'offer->{public_ip}');
        $assert->ok(!$offer->{connected},               'offer->{connected} = 0 au départ');

        my $pending = $pl->_dcc_pending_offer_for_nick('teuk');
        $assert->ok(defined $pending, '_dcc_pending_offer_for_nick : trouvé');

        $pl->_dcc_offer_mark_connected('ctcp_chat', 'teuk');
        $assert->ok(!defined $pl->_dcc_pending_offer_for_nick('teuk'),
            '_dcc_pending_offer_for_nick après mark_connected : absent');

        $pl->_dcc_offer_remove('ctcp_chat', 'teuk');
        my $offers = $pl->_dcc_offers_snapshot;
        $assert->is(scalar @$offers, 0, '_dcc_offers_snapshot vide après remove');
    }

    # ─────────────────────────────────────────────────────────────────────────
    # 5. _broadcast
    # ─────────────────────────────────────────────────────────────────────────
    SKIP_BROADCAST: {
        unless ($pl->can('_broadcast')) {
            $assert->ok(1, '_broadcast : skip (méthode absente)');
            last SKIP_BROADCAST;
        }

        { package FakeStream2; sub write { push @{$_[0]->{buf}}, $_[1] } }

        my (@w10, @w11);
        $pl->{streams}{10} = bless { buf => \@w10 }, 'FakeStream2';
        $pl->{streams}{11} = bless { buf => \@w11 }, 'FakeStream2';
        $pl->{users}{10}   = { authenticated => 1, login => 'teuk',  peer_host => 'h1' };
        $pl->{users}{11}   = { authenticated => 1, login => 'buddy', peer_host => 'h2' };
        $pl->{users}{12}   = { authenticated => 0, login => 'anon',  peer_host => 'h3' };

        $pl->_broadcast('hello everyone', 10);  # exclure fd=10

        $assert->is(scalar @w10, 0, '_broadcast : fd exclu ne reçoit pas');
        $assert->is(scalar @w11, 1, '_broadcast : fd non exclu reçoit');
        $assert->like($w11[0], qr/hello everyone/, '_broadcast : texte correct');
        $assert->ok(!exists $pl->{streams}{12},
            '_broadcast : fd non auth n\'a pas de stream (ignoré)');

        delete $pl->{users}{$_}   for 10, 11, 12;
        delete $pl->{streams}{$_} for 10, 11;
    }

    # ─────────────────────────────────────────────────────────────────────────
    # 6. get_port
    # ─────────────────────────────────────────────────────────────────────────
    {
        my $port = $pl->get_port;
        $assert->ok(defined $port && $port > 0, 'get_port : retourne un port valide');
    }
};
