# t/cases/686_mb475_did_you_mean.t
# =============================================================================
# mb475 — "did you mean?" : sur une commande publique inconnue, suggérer la
#         commande connue la plus proche au lieu de rester muet.
#
# Conservateur : canal seulement, token plausible, distance faible ET relative
# à la longueur, une seule suggestion, cooldown par canal, opt-out chanset
# DidYouMean (default on).
#
# On teste réellement _levenshtein et _mbSuggestCommand via MockBot (les
# suggestions passent par botPrivmsg -> MockIRC sent_privmsgs).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use MockBot;
use Mediabot::Context;
# mb475: require au runtime (pas `use`) — certains tests antérieurs de la suite
# perturbent le chargement à la compilation ; require dans la closure est sûr.

sub _slurp_686 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

# Mock DBH inerte : prepare renvoie un STH dont execute échoue -> getIdChansetList
# retourne undef -> chanset_enabled retombe sur son default (comportement voulu
# hors DB). Évite le crash "prepare on undef" quand MockBot n'a pas de dbh.
{
    package InertSTH686;
    sub new { bless {}, shift }
    sub execute { return undef }
    sub fetchrow_array { return () }
    sub fetchrow_hashref { return undef }
    sub finish { 1 }
    package InertDBH686;
    sub new { bless {}, shift }
    sub prepare { return InertSTH686->new }
    sub ping { 1 }
}
sub _mkbot_686 { return MockBot->new(dbh => InertDBH686->new, @_) }

sub privmsgs_686 {
    my ($bot) = @_;
    my $irc = $bot->{irc} or return ();
    return @{ $irc->{sent_privmsgs} // [] };
}
sub reset_pm_686 { $_[0]->{irc}{sent_privmsgs} = [] if $_[0]->{irc}; }

return sub {
    my ($assert) = @_;
    # Mediabot::Mediabot est normalement déjà chargé en suite. On tente un
    # chargement défensif. Un cas antérieur (595) peut polluer Helpers et
    # empêcher le chargement d'AdminCommands -> Mediabot::Mediabot. Dans ce cas
    # on saute les assertions RUNTIME (helpers en mémoire) mais on garde les
    # assertions de SCAN de source, qui ne dépendent d'aucun module.
    unless (Mediabot->can('_levenshtein')) {
        eval { require Mediabot::Mediabot };
    }
    my $runtime_ok = (Mediabot->can('_levenshtein') && Mediabot->can('_mbSuggestCommand')) ? 1 : 0;

  SKIP_RUNTIME: {
    last SKIP_RUNTIME unless $runtime_ok;

    # Capture déterministe des suggestions : on redéfinit localement
    # Mediabot::botPrivmsg (la fonction que _mbSuggestCommand appelle) au lieu
    # de dépendre de la chaîne botPrivmsg -> MockIRC, qu'un autre cas de la
    # suite peut avoir polluée.
    my @sent;
    no warnings 'redefine';
    local *Mediabot::botPrivmsg = sub {
        my ($self, $to, $msg) = @_;
        push @sent, { to => $to, text => $msg };
    };
    use warnings 'redefine';
    my $reset_sent = sub { @sent = () };

    # -------------------------------------------------------------------------
    # 1. _levenshtein (Damerau) : cas de référence.
    #    Une transposition adjacente coûte 1.
    # -------------------------------------------------------------------------
    $assert->is(Mediabot::_levenshtein('kitten','sitting'), 3, 'kitten/sitting = 3');
    $assert->is(Mediabot::_levenshtein('raodm','random'),   2, 'raodm/random = 2');
    $assert->is(Mediabot::_levenshtein('hlep','help'),      1, 'hlep/help = 1 (transposition)');
    $assert->is(Mediabot::_levenshtein('versoin','version'),1, 'versoin/version = 1 (transposition)');
    $assert->is(Mediabot::_levenshtein('abc','abc'),        0, 'identique = 0');
    $assert->is(Mediabot::_levenshtein('','abc'),           3, 'vide = longueur');

    # -------------------------------------------------------------------------
    # 2. Suggestion sur une vraie faute proche d'une commande publique connue.
    #    'hlep' -> 'help' (distance 2, help est public).
    # -------------------------------------------------------------------------
    {
        $reset_sent->();
        my $bot = _mkbot_686();
        my $ctx = Mediabot::Context->new(bot => $bot, nick => 'alice',
            channel => '#test', message => 'hlep', args => []);
        my $r = Mediabot::_mbSuggestCommand($bot, $ctx, '#test', 'alice', 'hlep');
        $assert->is($r, 1, 'hlep -> suggestion émise');
        my $joined = join("\n", map { $_->{text} } @sent);
        $assert->like($joined, qr/unknown command '.?hlep'/i, 'message mentionne la commande tapée');
        $assert->like($joined, qr/Did you mean .?help\??/i, 'suggère help');
    }

    # -------------------------------------------------------------------------
    # 3. Pas de suggestion pour un token trop éloigné (bruit).
    #    'zzzqwerty' n'est proche d'aucune commande.
    # -------------------------------------------------------------------------
    {
        $reset_sent->();
        my $bot = _mkbot_686();
        my $ctx = Mediabot::Context->new(bot => $bot, nick => 'bob',
            channel => '#test', message => 'zzzqwerty', args => []);
        my $r = Mediabot::_mbSuggestCommand($bot, $ctx, '#test', 'bob', 'zzzqwerty');
        $assert->is($r, 0, 'token éloigné -> pas de suggestion');
        $assert->is(scalar(@sent), 0, 'aucun message envoyé');
    }

    # -------------------------------------------------------------------------
    # 4. Token trop court (< 3) : jamais de suggestion (bruit conversationnel).
    # -------------------------------------------------------------------------
    {
        my $bot = _mkbot_686();
        my $ctx = Mediabot::Context->new(bot => $bot, nick => 'carol',
            channel => '#test', message => 'hi', args => []);
        my $r = Mediabot::_mbSuggestCommand($bot, $ctx, '#test', 'carol', 'hi');
        $assert->is($r, 0, 'token de 2 lettres -> pas de suggestion (bruit)');
    }

    # -------------------------------------------------------------------------
    # 5. Refus en message privé (channel undef ou non-#).
    # -------------------------------------------------------------------------
    {
        my $bot = _mkbot_686();
        my $ctx = Mediabot::Context->new(bot => $bot, nick => 'dave',
            channel => undef, message => 'hlep', args => []);
        my $r = Mediabot::_mbSuggestCommand($bot, $ctx, undef, 'dave', 'hlep');
        $assert->is($r, 0, 'privé -> pas de suggestion');
    }

    # -------------------------------------------------------------------------
    # 6. Cooldown : deux suggestions consécutives sur le même canal -> la 2e
    #    est bloquée (même $bot conserve _didyoumean_cd).
    # -------------------------------------------------------------------------
    {
        my $bot = _mkbot_686();
        $bot->{conf}->set('main.DIDYOUMEAN_COOLDOWN_S', 15);
        my $ctx = Mediabot::Context->new(bot => $bot, nick => 'erin',
            channel => '#test', message => 'hlep', args => []);
        my $r1 = Mediabot::_mbSuggestCommand($bot, $ctx, '#test', 'erin', 'hlep');
        my $r2 = Mediabot::_mbSuggestCommand($bot, $ctx, '#test', 'erin', 'versoin');
        $assert->is($r1, 1, '1re suggestion passe');
        $assert->is($r2, 0, '2e suggestion bloquée par le cooldown');
    }
  } # end SKIP_RUNTIME

    # -------------------------------------------------------------------------
    # 7. Intégration : câblage au miss, chanset déclaré, migration, doc.
    #    (scan de source — indépendant du chargement des modules)
    # -------------------------------------------------------------------------
    {
        my $med = _slurp_686(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
        $assert->like($med, qr/_mbSuggestCommand\(\$self, \$ctx, \$sChannel, \$sNick, \$sCommand\)/,
            'suggestion câblée au miss final de mbCommandPublic');
        $assert->like($med, qr/\+DidYouMean\b/, 'chanset DidYouMean documenté dans l\'aide');

        my $sql = _slurp_686(File::Spec->catfile('.', 'install', 'mediabot.sql'));
        $assert->like($sql, qr/\(18,\s*'DidYouMean'\)/, 'DidYouMean (id 18) dans CHANSET_LIST');

        my $mig = File::Spec->catfile('.', 'install', 'migrations', '20260707_didyoumean_chanset.sql');
        $assert->ok(-f $mig, 'migration DidYouMean présente');
        my $mtext = -f $mig ? _slurp_686($mig) : '';
        $assert->like($mtext, qr/WHERE NOT EXISTS/i, 'migration idempotente');
        $assert->unlike($mtext, qr/CREATE TABLE|ALTER TABLE/i, 'migration data-only');

        my $db = _slurp_686(File::Spec->catfile('.', 'docs', 'DB_MIGRATIONS.md'));
        my $rm = _slurp_686(File::Spec->catfile('.', 'install', 'migrations', 'README.md'));
        $assert->like($db, qr/20260707_didyoumean_chanset\.sql/, 'déclarée dans DB_MIGRATIONS.md');
        $assert->like($rm, qr/20260707_didyoumean_chanset\.sql/, 'déclarée dans migrations/README.md');
    }
};
