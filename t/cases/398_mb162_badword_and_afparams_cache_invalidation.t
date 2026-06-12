# t/cases/398_mb162_badword_and_afparams_cache_invalidation.t
# =============================================================================
# Tests des corrections mb162 :
#
#   - B1 : channelAddBadword_ctx invalidait le cache _badword_cache dans la
#          branche "already defined" (ou RIEN ne change en DB) et oubliait
#          de le faire apres l'INSERT reussi (la branche qui change les
#          donnees). Consequence : un badword fraichement ajoute n'etait
#          pas filtre par botPrivmsg pendant jusqu'a 5 minutes (TTL).
#          Fix complementaire : cle de cache canonique (la casse tapee par
#          l'utilisateur peut differer du nom canonique keyant le cache).
#
#   - B2 : setChannelAntiFloodParams_ctx faisait l'UPDATE CHANNEL_FLOOD
#          sans invalider le cache runtime _af_params de checkAntiFlood
#          (TTL OUTPUT_PARAMS_CACHE_TTL, 60s par defaut, configurable
#          jusqu'a 24h). Les nouveaux parametres ne prenaient effet qu'a
#          l'expiration du TTL, silencieusement.
# =============================================================================

use strict;
use warnings;

return sub {
    my ($assert) = @_;

    # =========================================================================
    # B1 : cycle de vie du cache badword
    # =========================================================================

    # Mini-simulation du filtre botPrivmsg (TTL 300s)
    my $make_filter = sub {
        my ($bot, $db_ref) = @_;
        return sub {
            my ($chan, $msg, $t) = @_;
            my $cache = $bot->{_badword_cache}{$chan};
            if (!$cache || ($t - ($cache->{ts} // 0)) > 300) {
                $bot->{_badword_cache}{$chan} = { ts => $t, words => [@$db_ref] };
                $cache = $bot->{_badword_cache}{$chan};
            }
            for my $bw (@{ $cache->{words} // [] }) {
                return 0 if index(lc($msg), $bw) != -1;  # blocked
            }
            return 1;  # sent
        };
    };

    # -------------------------------------------------------------------------
    # Cas 1 : REGRESSION-POC — badword ajoute non filtre (cache stale)
    # -------------------------------------------------------------------------
    {
        my $bot = { _badword_cache => {} };
        my @db  = ();
        my $f   = $make_filter->($bot, \@db);

        $assert->($f->('#chan', 'achetez du spam', 1000) == 1,
            "B1 t=1000: 'spam' pas encore badword -> message passe");

        # addbadword (BUGGY: pas d invalidation apres INSERT)
        push @db, 'spam';

        $assert->($f->('#chan', 'achetez du spam', 1015) == 1,
            "B1 REGRESSION-POC: badword ajoute mais cache stale -> message passe encore");
    }

    # -------------------------------------------------------------------------
    # Cas 2 : FIX — invalidation apres INSERT -> filtrage immediat
    # -------------------------------------------------------------------------
    {
        my $bot = { _badword_cache => {} };
        my @db  = ();
        my $f   = $make_filter->($bot, \@db);

        $f->('#chan', 'warmup', 1000);   # prime le cache

        # addbadword (FIXED: invalidation apres INSERT)
        push @db, 'spam';
        delete $bot->{_badword_cache}{'#chan'};

        $assert->($f->('#chan', 'achetez du spam', 1015) == 0,
            "B1 FIX: invalidation apres INSERT -> badword filtre immediatement");
    }

    # -------------------------------------------------------------------------
    # Cas 3 : branche already-exists — aucune invalidation necessaire
    # -------------------------------------------------------------------------
    {
        my $bot = { _badword_cache => {} };
        my @db  = ('spam');
        my $f   = $make_filter->($bot, \@db);

        $f->('#chan', 'warmup', 1000);   # prime (avec spam dedans)

        # addbadword d'un mot deja existant : la DB ne change pas.
        # Le nouveau code ne touche pas au cache -> toujours coherent.
        my $cache_before = $bot->{_badword_cache}{'#chan'}{ts};
        # (no-op)
        my $cache_after  = $bot->{_badword_cache}{'#chan'}{ts};

        $assert->($cache_before == $cache_after,
            "B1 already-exists: cache intact (pas d invalidation inutile)");
        $assert->($f->('#chan', 'du spam ici', 1020) == 0,
            "B1 already-exists: filtrage continue de fonctionner");
    }

    # -------------------------------------------------------------------------
    # Cas 4 : rembadword — invalidation correcte (deja en place, preservee)
    # -------------------------------------------------------------------------
    {
        my $bot = { _badword_cache => {} };
        my @db  = ('spam');
        my $f   = $make_filter->($bot, \@db);

        $assert->($f->('#chan', 'du spam', 1000) == 0,
            "B1 rembadword setup: 'spam' bloque");

        # rembadword + invalidation
        @db = ();
        delete $bot->{_badword_cache}{'#chan'};

        $assert->($f->('#chan', 'du spam', 1010) == 1,
            "B1 rembadword: apres suppression + invalidation, message passe");
    }

    # -------------------------------------------------------------------------
    # Cas 5 : cle canonique — la casse tapee differe du nom canonique
    # -------------------------------------------------------------------------
    {
        my $bot = { _badword_cache => { '#hardware' => { ts => 1000, words => [] } } };

        # BUGGY: delete avec la casse tapee -> rate la cle
        my $typed = '#Hardware';
        delete $bot->{_badword_cache}{$typed};
        $assert->(exists $bot->{_badword_cache}{'#hardware'},
            "B1 REGRESSION-POC casse: delete '#Hardware' rate la cle '#hardware'");

        # FIXED: delete canonique + casse tapee
        my $canon = '#hardware';   # via channel_obj->get_name
        delete $bot->{_badword_cache}{$canon};
        delete $bot->{_badword_cache}{$typed} if $typed ne $canon;
        $assert->(!exists $bot->{_badword_cache}{'#hardware'},
            "B1 FIX casse: cle canonique invalidee");
    }

    # =========================================================================
    # B2 : cache _af_params de checkAntiFlood
    # =========================================================================

    my $make_af = sub {
        my ($bot, $db_ref) = @_;
        return sub {
            my ($chan, $t, $ttl) = @_;
            my $pc = $bot->{_af_params}{$chan} // {};
            if (!$pc->{ts} || ($t - $pc->{ts}) >= $ttl) {
                $bot->{_af_params}{$chan} = { ts => $t, %$db_ref };
                $pc = $bot->{_af_params}{$chan};
            }
            return ($pc->{nbmsg_max}, $pc->{duration});
        };
    };

    # -------------------------------------------------------------------------
    # Cas 6 : REGRESSION-POC — UPDATE sans invalidation = stale jusqu'au TTL
    # -------------------------------------------------------------------------
    {
        my $bot = { _af_params => {} };
        my %db  = ( nbmsg_max => 5, duration => 30 );
        my $af  = $make_af->($bot, \%db);
        my $ttl = 3600;  # OUTPUT_PARAMS_CACHE_TTL = 1h

        my ($m, $d) = $af->('#chan', 1000, $ttl);
        $assert->($m == 5 && $d == 30,
            "B2 t=1000: params initiaux 5/30s caches");

        # antifloodset 2 10 ... a t=1060 (BUGGY: pas d invalidation)
        %db = ( nbmsg_max => 2, duration => 10 );

        ($m, $d) = $af->('#chan', 2000, $ttl);
        $assert->($m == 5 && $d == 30,
            "B2 REGRESSION-POC: a t=2000 le runtime sert encore 5/30s (stale)");

        ($m, $d) = $af->('#chan', 1000 + $ttl, $ttl);
        $assert->($m == 2 && $d == 10,
            "B2 REGRESSION-POC: les nouveaux params n'arrivent qu'a l'expiration du TTL");
    }

    # -------------------------------------------------------------------------
    # Cas 7 : FIX — invalidation apres UPDATE = application immediate
    # -------------------------------------------------------------------------
    {
        my $bot = { _af_params => {} };
        my %db  = ( nbmsg_max => 5, duration => 30 );
        my $af  = $make_af->($bot, \%db);
        my $ttl = 3600;

        $af->('#chan', 1000, $ttl);   # prime

        # antifloodset 2 10 ... + invalidation (FIX)
        %db = ( nbmsg_max => 2, duration => 10 );
        delete $bot->{_af_params}{'#chan'};

        my ($m, $d) = $af->('#chan', 1061, $ttl);
        $assert->($m == 2 && $d == 10,
            "B2 FIX: invalidation apres UPDATE -> nouveaux params immediats");
    }

    # -------------------------------------------------------------------------
    # Cas 8 : FIX — invalidation des deux casses (canonique + tapee)
    # -------------------------------------------------------------------------
    {
        my $bot = {
            _af_params       => { '#chan' => { ts => 1000, nbmsg_max => 5 } },
            _chan_flood_conf => { '#chan' => { warn_only => 1 } },
        };
        my $canon = '#chan';
        my $typed = '#CHAN';
        for my $k ($canon, $typed) {
            delete $bot->{_af_params}{$k}       if $bot->{_af_params};
            delete $bot->{_chan_flood_conf}{$k} if $bot->{_chan_flood_conf};
        }
        $assert->(!exists $bot->{_af_params}{'#chan'},
            "B2 FIX: _af_params invalide via cle canonique");
        $assert->(!exists $bot->{_chan_flood_conf}{'#chan'},
            "B2 FIX: _chan_flood_conf invalide aussi (coherence overrides)");
    }
};
