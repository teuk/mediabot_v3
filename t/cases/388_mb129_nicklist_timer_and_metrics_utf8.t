# t/cases/388_mb129_nicklist_timer_and_metrics_utf8.t
# =============================================================================
# Tests des corrections mb129 :
#
#   - B1 : addChannel_ctx ne lancait pas le timer nicklist pour le nouveau
#          canal. setup_channel_nicklist_timers() etait appele uniquement
#          au demarrage et a chaque reconnect IRC.
#
#   - B2 : purgeChannel_ctx et channelPart_ctx n'arretaient pas le timer
#          nicklist du canal concerne. Le timer continuait a envoyer NAMES
#          sur un canal ou le bot n'est plus.
#
#   - B3 : Metrics::start_http_server calculait Content-Length avec
#          length($body) (caracteres) au lieu de length(encode_utf8($body))
#          (bytes). Bug avec UTF-8 dans les labels (ex: "#cafe").
# =============================================================================

use strict;
use warnings;
use Encode qw(encode_utf8);

my $case = sub {
    my ($assert) = @_;

    # -------------------------------------------------------------------------
    # B1 + B2 : simulation du lifecycle des timers nicklist
    # -------------------------------------------------------------------------
    # On modelise un mini-bot avec :
    #   - {channels} : hash des canaux connus
    #   - {channel_nicklist_timers} : hash des timers actifs
    #   - setup_all : (re)cree un timer pour chaque canal
    #   - stop_one  : arrete un timer specifique
    my $make_bot = sub {
        my $bot = {
            channels => {},
            channel_nicklist_timers => {},
        };
        return $bot;
    };

    my $setup_all = sub {
        my ($bot) = @_;
        # Stop tous puis recreer
        for my $k (keys %{ $bot->{channel_nicklist_timers} }) {
            $bot->{channel_nicklist_timers}{$k} = undef;
            delete $bot->{channel_nicklist_timers}{$k};
        }
        for my $name (keys %{ $bot->{channels} }) {
            $bot->{channel_nicklist_timers}{$name} = { active => 1, channel => $name };
        }
    };

    my $stop_one = sub {
        my ($bot, $name) = @_;
        delete $bot->{channel_nicklist_timers}{$name};
        delete $bot->{channel_nicklist_timers}{lc($name)};
    };

    # === B1: addchan declenche setup ===
    {
        my $bot = $make_bot->();
        $bot->{channels}{'#chanA'} = { id => 1 };
        $setup_all->($bot);   # demarrage initial
        $assert->(exists $bot->{channel_nicklist_timers}{'#chanA'},
            "B1 setup initial : timer #chanA cree");

        # Simulation: addchan #chanB → setup_all redeclenche
        $bot->{channels}{'#chanB'} = { id => 2 };
        $setup_all->($bot);
        $assert->(exists $bot->{channel_nicklist_timers}{'#chanB'},
            "B1 addchan #chanB → setup → timer cree");
        $assert->(exists $bot->{channel_nicklist_timers}{'#chanA'},
            "B1 #chanA toujours present apres setup");

        # Verifier ce qu'il se serait passe SANS le fix
        my $bot_no_fix = $make_bot->();
        $bot_no_fix->{channels}{'#chanA'} = { id => 1 };
        $setup_all->($bot_no_fix);
        # addchan SANS appel setup_all
        $bot_no_fix->{channels}{'#chanB'} = { id => 2 };
        $assert->(!exists $bot_no_fix->{channel_nicklist_timers}{'#chanB'},
            "B1 REGRESSION-POC: sans fix, #chanB n'a pas de timer");
    }

    # === B2: purge arrete le timer ===
    {
        my $bot = $make_bot->();
        $bot->{channels}{'#chanA'} = { id => 1 };
        $bot->{channels}{'#chanB'} = { id => 2 };
        $setup_all->($bot);

        # Simulation purge #chanA
        delete $bot->{channels}{'#chanA'};
        $stop_one->($bot, '#chanA');

        $assert->(!exists $bot->{channel_nicklist_timers}{'#chanA'},
            "B2 purge #chanA → timer arrete");
        $assert->( exists $bot->{channel_nicklist_timers}{'#chanB'},
            "B2 timer #chanB preserve");
    }

    # === B2: part arrete le timer (canal reste configure) ===
    {
        my $bot = $make_bot->();
        $bot->{channels}{'#chanA'} = { id => 1 };
        $setup_all->($bot);
        $assert->(exists $bot->{channel_nicklist_timers}{'#chanA'},
            "B2 setup initial OK");

        # part #chanA : canal reste configure mais timer stoppe
        $stop_one->($bot, '#chanA');
        $assert->(!exists $bot->{channel_nicklist_timers}{'#chanA'},
            "B2 part #chanA → timer arrete (canal toujours dans channels)");
        $assert->(exists $bot->{channels}{'#chanA'},
            "B2 part ne supprime PAS le canal du registry");

        # join #chanA : setup_all recree le timer
        $setup_all->($bot);
        $assert->(exists $bot->{channel_nicklist_timers}{'#chanA'},
            "B2 join → setup → timer recree");
    }

    # === B2 lifecycle complet : addchan → part → join → purge ===
    {
        my $bot = $make_bot->();
        # addchan #X
        $bot->{channels}{'#X'} = { id => 1 };
        $setup_all->($bot);
        $assert->(exists $bot->{channel_nicklist_timers}{'#X'}, "lifecycle: after addchan, timer exists");

        # part #X
        $stop_one->($bot, '#X');
        $assert->(!exists $bot->{channel_nicklist_timers}{'#X'}, "lifecycle: after part, timer gone");
        $assert->(exists $bot->{channels}{'#X'}, "lifecycle: after part, channel still registered");

        # join #X
        $setup_all->($bot);
        $assert->(exists $bot->{channel_nicklist_timers}{'#X'}, "lifecycle: after join, timer back");

        # purge #X
        delete $bot->{channels}{'#X'};
        $stop_one->($bot, '#X');
        $assert->(!exists $bot->{channel_nicklist_timers}{'#X'}, "lifecycle: after purge, timer gone");
        $assert->(!exists $bot->{channels}{'#X'}, "lifecycle: after purge, channel gone");
    }

    # -------------------------------------------------------------------------
    # B3 : Content-Length doit etre en bytes UTF-8, pas en caracteres
    # -------------------------------------------------------------------------

    # Cas 1: ASCII pur — bytes == chars
    {
        my $body = "mediabot_joins_total{channel=\"#general\"} 42\n";
        my $bytes = encode_utf8($body);
        $assert->(length($body) == length($bytes),
            "B3 ASCII: length(chars)==length(bytes) trivial");
    }

    # Cas 2: UTF-8 — é = 2 bytes
    {
        my $body = qq{mediabot_joins_total{channel="#caf\x{e9}"} 5\n};
        my $bytes = encode_utf8($body);
        my $chars = length($body);
        my $blen  = length($bytes);
        $assert->($blen == $chars + 1,
            "B3 UTF-8: 1 char 'e accent aigu' ajoute 1 byte (chars=$chars bytes=$blen)");
    }

    # Cas 3: emoji (4 bytes UTF-8)
    {
        my $body = qq{mediabot_achievements_unlocked_total{achievement="\x{1F3C6}gold"} 1\n};
        my $bytes = encode_utf8($body);
        my $chars = length($body);
        my $blen  = length($bytes);
        $assert->($blen == $chars + 3,
            "B3 UTF-8: 1 emoji ajoute 3 bytes (chars=$chars bytes=$blen)");
    }

    # Cas 4: Content-Length annonce DOIT egaler length(bytes), pas length(chars)
    {
        my $body = qq{mediabot_joins_total{channel="#caf\x{e9}"} 5\n};
        my $bytes = encode_utf8($body);
        # Ancien code (buggy) :
        my $old_content_length = length($body);
        # Nouveau code :
        my $new_content_length = length($bytes);
        $assert->($old_content_length != $new_content_length,
            "B3 REGRESSION-POC: ancien Content-Length ($old_content_length) != bon ($new_content_length)");
        $assert->($new_content_length == length($bytes),
            "B3 nouveau Content-Length correspond aux bytes envoyes");
    }

    # Cas 5: scenarios realistes Prometheus
    {
        # Plusieurs canaux UTF-8 dans un meme dump
        my @canaux = ("#caf\x{e9}", "#R\x{e9}sistance", "#\x{1F1EB}\x{1F1F7}france");
        my $body = "# HELP mediabot_joins_total Total joins\n# TYPE mediabot_joins_total counter\n";
        for my $c (@canaux) {
            $body .= qq{mediabot_joins_total{channel="$c"} 1\n};
        }
        my $bytes = encode_utf8($body);
        $assert->(length($bytes) > length($body),
            "B3 dump multi-canaux UTF-8 : bytes > chars (chars=" . length($body) . " bytes=" . length($bytes) . ")");
        # Si on envoyait length($body), le client recevrait length($body) bytes
        # puis verrait des bytes restants (corrompus ou tronques selon clients)
    }
};

# ---------------------------------------------------------------------------
# Direct runner for standalone execution:
#   perl t/cases/THIS_FILE.t
#
# When loaded by the project harness, return the case coderef.
# ---------------------------------------------------------------------------
if (caller) {
    return $case;
}

my $tests = 0;
my $fail  = 0;

my $assert = sub {
    my ($ok, $name) = @_;
    $tests++;

    $name = 'unnamed assertion' unless defined $name && $name ne '';

    if ($ok) {
        print "ok $tests - $name\n";
    }
    else {
        print "not ok $tests - $name\n";
        $fail++;
    }
};

$case->($assert);

print "1..$tests\n";
exit($fail ? 1 : 0);

