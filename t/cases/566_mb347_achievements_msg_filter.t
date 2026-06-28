# t/cases/566_mb347_achievements_msg_filter.t
# =============================================================================
# mb347 — check_msg ne doit compter que les vrais messages.
#
# check_msg filtrait par `publictext IS NOT NULL`. Or logBotAction stocke
# publictext verbatim : join/part s'enregistrent avec '' (chaîne vide, qui est
# IS NOT NULL en SQL), et kick/mode/topic/notice avec du texte. Tous ces
# non-messages étaient donc comptés -> achievements de volume gonflés
# (chatterbox/megaphone/night_owl/polyphony débloqués en rejoignant en boucle).
#
# mb347 remplace le filtre par `event_type IN ('public','action')` (convention
# "a parlé" du reste du code).
#
# Pas de DBI réel : on valide (a) la SÉMANTIQUE des deux filtres sur une fixture
# CHANNEL_LOG représentative, et (b) la présence du bon filtre dans le source.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

# Fixture CHANNEL_LOG : [event_type, publictext]   (undef = SQL NULL)
my @CLOG = (
    ['public', 'hello'],
    ['public', 'world'],
    ['action', 'waves'],
    ['join',   ''],           # join : publictext='' (NON NULL en SQL)
    ['part',   ''],           # part vide : ''
    ['part',   'bye all'],    # part avec raison
    ['quit',   'ping timeout'],
    ['kick',   'bob (flood)'],
    ['mode',   '+o bob'],
    ['topic',  'new topic text'],
    ['notice', 'some notice'],
);

# old: publictext IS NOT NULL  ==  defined($publictext)
sub _count_old { my $n = 0; defined($_->[1]) and $n++ for @CLOG; return $n; }
# new: event_type IN ('public','action')
sub _count_new {
    my $n = 0;
    for (@CLOG) { $n++ if $_->[0] eq 'public' || $_->[0] eq 'action'; }
    return $n;
}

sub _slurp_566 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    # --- 1. Sémantique ----------------------------------------------------
    # Ancien filtre : tout est compté (les 11 lignes ont un publictext défini,
    # '' compris) -> énorme sur-comptage.
    $assert->is(_count_old(), 11, 'témoin: publictext IS NOT NULL compte aussi join/part/kick/mode/topic/notice');
    # Nouveau filtre : seulement les 3 vrais messages (2 public + 1 action).
    $assert->is(_count_new(), 3, 'nouveau: seuls public+action comptent');

    # --- 2. Scan de source ------------------------------------------------
    my $src = _slurp_566(File::Spec->catfile('.', 'Mediabot', 'Achievements.pm'));
    my ($cm) = $src =~ /(sub check_msg \{.*?\n\}\n)/s;
    $cm //= '';
    $assert->ok($cm ne '', 'sub check_msg extraite');

    # Les 3 requêtes de check_msg utilisent le filtre event_type.
    # On compte sur le SQL hors commentaires (le commentaire d'en-tête cite aussi
    # la clause).
    my $sql_for_count = $cm;
    $sql_for_count =~ s/^\s*#.*$//mg;     # retire les commentaires Perl
    $sql_for_count =~ s/--.*$//mg;        # retire les commentaires SQL
    my $n_evt = () = $sql_for_count =~ /event_type IN \('public','action'\)/g;
    $assert->is($n_evt, 3, 'check_msg: les 3 requêtes filtrent event_type IN (public,action)');

    # Plus aucun `publictext IS NOT NULL` dans le SQL de check_msg (hors commentaires).
    my $sql_only = $cm;
    $sql_only =~ s/^\s*#.*$//mg;     # retire les lignes de commentaire Perl
    $sql_only =~ s/--.*$//mg;        # retire les commentaires SQL
    $assert->unlike($sql_only, qr/publictext IS NOT NULL/,
                    'check_msg: plus de publictext IS NOT NULL dans le SQL');

    $assert->like($cm, qr/mb347-B1/, 'tag mb347-B1 présent');
};
