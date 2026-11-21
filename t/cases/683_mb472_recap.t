# t/cases/683_mb472_recap.t
# =============================================================================
# mb472 — !recap : résumé de ce qui a été manqué sur un canal.
#
# Fonctionnalité vitrine (direction 3.3 §5). Lecture seule de CHANNEL_LOG +
# USER_SEEN, sortie en NOTICE privé, garde-fous (fenêtre bornée, cooldown).
#
# Ce test exécute réellement mbRecap_ctx via MockBot + un faux DBH scénarisé,
# et vérifie l'intégration (export, dispatch, help, conf).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use DBI ();
use JSON::PP ();

use MockBot;
use Mediabot::Context;
use Mediabot::UserCommands;

sub _slurp_683 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

# --- Faux channel object avec get_id ---
{
    package FakeChan683;
    sub new { bless { id => $_[1] }, $_[0] }
    sub get_id { $_[0]->{id} }
}

# --- Faux DBH scénarisé : renvoie des lignes CHANNEL_LOG programmées ---
{
    package FakeSTH683;
    sub new { bless { rows => $_[1] // [], i => 0, seen => $_[2] }, $_[0] }
    sub execute { $_[0]->{i} = 0; 1 }
    sub fetchrow_hashref { my $s=shift; return undef if $s->{i} >= @{$s->{rows}}; return $s->{rows}[$s->{i}++]; }
    sub fetchrow_array   { my $s=shift; return defined $s->{seen} ? ($s->{seen}) : (); }
    sub err { 0 }
    sub finish { 1 }

    package FakeDBH683;
    sub new { bless { rows => $_[1] // [], seen => $_[2] }, $_[0] }
    sub prepare {
        my ($self, $sql) = @_;
        if ($sql =~ /USER_SEEN/) {
            return FakeSTH683->new([], $self->{seen});   # fetchrow_array -> seen
        }
        return FakeSTH683->new($self->{rows});           # CHANNEL_LOG rows
    }
}

{
    package RecapDB683; our @ISA = ('DBI');
    package RecapDB683::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db, $sql, @rest) = @_;
        my $state = $db->{private_mb1399};
        return $db->SUPER::prepare($sql, @rest) unless $state && $sql =~ /FROM CHANNEL_LOG/;
        return $db->set_err(1, 'recap fixture prepare failure') if $state->{fault} eq 'prepare';
        $sql =~ s/UNIX_TIMESTAMP\(ts\)/CAST(strftime('%s', ts) AS INTEGER)/;
        $sql =~ s/DATE_SUB\(NOW\(\), INTERVAL \? SECOND\)/datetime('2026-11-21 12:00:00', printf('-%d seconds', ?))/;
        my $sth = $db->SUPER::prepare($sql, @rest);
        $sth->{private_mb1399} = $state if $sth;
        return $sth;
    }
    package RecapDB683::st; our @ISA = ('DBI::st');
    sub execute {
        my ($sth, @bind) = @_;
        my $state = $sth->{private_mb1399};
        return $sth->set_err(1, 'recap fixture execute failure') if $state && $state->{fault} eq 'execute';
        return $sth->SUPER::execute(@bind);
    }
    sub fetchrow_hashref {
        my ($sth, @args) = @_;
        my $state = $sth->{private_mb1399};
        my $row = $sth->SUPER::fetchrow_hashref(@args);
        if ($state) {
            my $read = ++$state->{reads};
            my $fault = $state->{fault};
            if (($fault eq 'first_fetch' && $read == 1)
                    || (($fault eq 'partial_fetch' || $fault eq 'flagged_row') && $read == 2)) {
                $sth->set_err(1, 'recap fixture fetch failure');
                return $fault eq 'flagged_row' ? $row : undef;
            }
        }
        return $row;
    }
    sub finish {
        my ($sth) = @_;
        my $state = $sth->{private_mb1399};
        $state->{finished}++ if $state;
        return $sth->SUPER::finish;
    }
    package RecapMetrics683;
    sub inc { push @{$_[0]}, $_[1] }
}
$INC{'RecapDB683.pm'} = __FILE__;

sub make_ctx_683 {
    my (%o) = @_;
    my $bot = MockBot->new(
        dbh      => $o{dbh} // FakeDBH683->new($o{rows} // [], $o{seen}),
        channels => { lc($o{channel} // '#test') => FakeChan683->new(42) },
    );
    # clés de conf recap éventuelles
    if ($o{conf}) { $bot->{conf}->set("main.$_", $o{conf}{$_}) for keys %{$o{conf}} }
    my $ctx = Mediabot::Context->new(
        bot     => $bot,
        nick    => $o{nick}    // 'alice',
        channel => $o{channel}, # undef => privé
        message => $o{message} // 'recap',
        args    => $o{args}    // [],
    );
    return ($bot, $ctx);
}

sub notices_683 {
    my ($bot) = @_;
    my $irc = $bot->{irc} or return ();
    return @{ $irc->{sent_notices} // [] };
}

# purge des notices capturées entre deux sous-cas
sub reset_notices_683 {
    my ($bot) = @_;
    $bot->{irc}{sent_notices} = [] if $bot->{irc};
}

return sub {
    my ($assert) = @_;

    # -------------------------------------------------------------------------
    # 1. Refus en message privé (pas de canal).
    # -------------------------------------------------------------------------
    {
        my ($bot, $ctx) = make_ctx_683(channel => undef, args => []);
        Mediabot::UserCommands::mbRecap_ctx($ctx);
        my @n = notices_683($bot);
        $assert->ok((grep { $_->{text} =~ /use it in a channel|Syntax: recap/i } @n),
            'recap en privé -> message de syntaxe (refus)');
    }

    # -------------------------------------------------------------------------
    # 2. Rien à recaper -> message "nothing much happened".
    # -------------------------------------------------------------------------
    {
        my ($bot, $ctx) = make_ctx_683(channel => '#test', rows => [], args => ['30m']);
        Mediabot::UserCommands::mbRecap_ctx($ctx);
        my @n = notices_683($bot);
        $assert->ok((grep { $_->{text} =~ /nothing much happened/i } @n),
            'fenêtre vide -> nothing much happened');
    }

    # -------------------------------------------------------------------------
    # 3. Messages présents -> résumé statistique (count + top + échantillon).
    #    L'appelant (alice) ne doit pas se recaper elle-même.
    # -------------------------------------------------------------------------
    {
        my $now = time();
        my @rows = (
            { nick => 'bob',   publictext => 'hello everyone',  t => $now - 300 },
            { nick => 'carol', publictext => 'hi bob',          t => $now - 240 },
            { nick => 'bob',   publictext => 'what is up',      t => $now - 120 },
            { nick => 'alice', publictext => 'my own message',  t => $now - 60  },
        );
        my ($bot, $ctx) = make_ctx_683(channel => '#test', nick => 'alice',
                                       rows => \@rows, args => ['2h']);
        Mediabot::UserCommands::mbRecap_ctx($ctx);
        my @n = notices_683($bot);
        my $joined = join("\n", map { $_->{text} } @n);
        $assert->like($joined, qr/recap #test .*3 message/,
            'compte 3 messages (exclut le message d\'alice)');
        $assert->like($joined, qr/Top:.*bob \(2\)/,
            'top parleurs : bob (2) en tête');
        $assert->like($joined, qr/First: <bob> hello everyone/,
            'échantillon : première ligne');
        $assert->unlike($joined, qr/my own message/,
            'le message de l\'appelant est exclu du recap');
    }

    # -------------------------------------------------------------------------
    # A failed history cursor must not publish stats or send a partial transcript.
    # -------------------------------------------------------------------------
    {
        no warnings qw(redefine once);
        require Mediabot::External::Claude;
        my @prompts;
        local *Mediabot::External::Claude::claudeAI = sub {
            push @prompts, $_[1];
            $_[4]->('fixture summary');
            return 1;
        };
        my $json = JSON::PP->new;
        for my $raise (0, 1) {
            my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {
                RootClass => 'RecapDB683', RaiseError => $raise, PrintError => 0,
            });
            $db->do('CREATE TABLE CHANNEL_LOG (id_channel INTEGER, nick TEXT, publictext TEXT, ts TEXT, event_type TEXT)');
            $db->do(q{INSERT INTO CHANNEL_LOG VALUES
                (42,'bob','first fixture','2026-11-21 11:50:00','public'),
                (42,'carol','second fixture','2026-11-21 11:55:00','action')});
            for my $fault (qw(prepare execute first_fetch partial_fetch flagged_row)) {
                for my $ai (0, 1) {
                    my $state = {fault => $fault, reads => 0, finished => 0};
                    $db->{private_mb1399} = $state;
                    my ($bot, $ctx) = make_ctx_683(dbh => $db, channel => '#test',
                        args => ['30m', ($ai ? 'ai' : ())], conf => {RECAP_COOLDOWN_S => 0});
                    $bot->{conf}->set('anthropic.API_KEY', 'fixture');
                    my $metrics = $bot->{metrics} = bless [], 'RecapMetrics683';
                    @prompts = ();
                    my $ok = eval { Mediabot::UserCommands::mbRecap_ctx($ctx); 1 };
                    my @notices = map { [$_->{target}, $_->{text}] } notices_683($bot);
                    my $accounted = grep { $_ eq 'mediabot_recap_total' } @$metrics;
                    my $expected_finish = $fault eq 'prepare' ? 0 : 1;
                    $assert->is(
                        $json->encode([$ok // 0, \@notices, scalar(@prompts), $accounted, $state->{finished}]),
                        $json->encode([1, [['alice', 'recap: could not read the channel log.']], 0, 0, $expected_finish]),
                        "recap read failure ($fault, RaiseError=$raise, ai=$ai) closes the cursor and reports only a private error");
                }
            }
            $db->{private_mb1399} = {fault => '', reads => 0, finished => 0};
            my ($bot, $ctx) = make_ctx_683(dbh => $db, channel => '#test', args => ['30m', 'ai']);
            $bot->{conf}->set('anthropic.API_KEY', 'fixture');
            @prompts = ();
            Mediabot::UserCommands::mbRecap_ctx($ctx);
            $assert->is(scalar(@prompts), 1, "recap ai recovers on the same DBI handle (RaiseError=$raise)");
            $assert->like($prompts[0] // '', qr/<bob> first fixture\n<carol> second fixture\n/,
                "recap ai uses both rows after a complete read (RaiseError=$raise)");
            $db->disconnect;
        }
    }

    # -------------------------------------------------------------------------
    # 4. Cooldown : deux recaps consécutifs -> le 2e est bloqué.
    # -------------------------------------------------------------------------
    {
        my ($bot, $ctx) = make_ctx_683(channel => '#test', nick => 'dave',
                                       rows => [], args => ['30m'],
                                       conf => { RECAP_COOLDOWN_S => 30 });
        Mediabot::UserCommands::mbRecap_ctx($ctx);
        reset_notices_683($bot);
        # 2e appel immédiat, même bot (même état _recap_cooldown)
        my $ctx2 = Mediabot::Context->new(
            bot => $bot, nick => 'dave', channel => '#test',
            message => 'recap', args => ['30m']);
        Mediabot::UserCommands::mbRecap_ctx($ctx2);
        my @n = notices_683($bot);
        $assert->ok((grep { $_->{text} =~ /please wait \d+s/i } @n),
            'cooldown : 2e recap immédiat bloqué');
    }

    # -------------------------------------------------------------------------
    # 5. Cap de fenêtre : RECAP_MAX_H borne une demande trop grande.
    #    On demande 99h avec un cap à 2h -> le label doit indiquer "capped".
    # -------------------------------------------------------------------------
    {
        my ($bot, $ctx) = make_ctx_683(channel => '#test', nick => 'erin',
                                       rows => [ { nick=>'bob', publictext=>'x', t=>time()-60 } ],
                                       args => ['99h'],
                                       conf => { RECAP_MAX_H => 2 });
        Mediabot::UserCommands::mbRecap_ctx($ctx);
        my @n = notices_683($bot);
        my $joined = join("\n", map { $_->{text} } @n);
        $assert->like($joined, qr/2h \(capped\)/, 'fenêtre plafonnée à RECAP_MAX_H');
    }

    # -------------------------------------------------------------------------
    # 6. Intégration : export, dispatch, help, conf documentée.
    # -------------------------------------------------------------------------
    {
        my $uc = _slurp_683(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
        $assert->like($uc, qr/^\s*mbRecap_ctx\s*$/m, 'mbRecap_ctx exporté');

        my $med = _slurp_683(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
        $assert->like($med,
            qr/recap\s*=>\s*sub\s*\{\s*my \(\$ctx\) = \@_;\s*mbRecap_ctx/,
            'recap enregistré dans le registre public');
        $assert->like($med, qr/recap\|recap.*\|public\|/,
            'recap documenté dans les métadonnées help');

        my $conf = _slurp_683(File::Spec->catfile('.', 'mediabot.sample.conf'));
        $assert->like($conf, qr/RECAP_MAX_H=/,      'RECAP_MAX_H dans la sample conf');
        $assert->like($conf, qr/RECAP_COOLDOWN_S=/, 'RECAP_COOLDOWN_S dans la sample conf');
    }

    # -------------------------------------------------------------------------
    # 7. Périmètre : aucune écriture SQL dans le handler (lecture seule).
    # -------------------------------------------------------------------------
    {
        my $uc = _slurp_683(File::Spec->catfile('.', 'Mediabot', 'SocialHistory.pm'));
        my ($body) = $uc =~ /(sub mbRecap_ctx \{.*?\n\}\n)/s;
        $body //= '';
        # On cible les vraies instructions SQL d'écriture (mot-clé + contexte SQL),
        # pas le `delete $hash{...}` de Perl utilisé pour purger le cooldown.
        $assert->unlike($body,
            qr/\b(?:INSERT\s+INTO|UPDATE\s+\w+\s+SET|DELETE\s+FROM|REPLACE\s+INTO|ALTER\s+TABLE|CREATE\s+(?:TABLE|INDEX)|DROP\s+(?:TABLE|INDEX))\b/i,
            'mbRecap_ctx est en lecture seule (aucune écriture SQL)');
    }
};
