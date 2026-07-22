# t/cases/741_mb544_lusers_debug_partyline.t
# =============================================================================
# mb544 — « la moindre des choses » : les détails du LUSERS visibles en debug
# niveau 3 (log) et en partyline, adossés à un cache cœur indépendant du
# système Metrics.
#
# Contrats :
#   [1] chaque numeric qui extrait des valeurs logge UNE ligne niveau 3 avec
#       les paires clé=valeur (et la requête périodique/partyline logge aussi
#       en 3 — debug 3 all included) ;
#   [2] cache cœur network_stats : peuplé au parsing (avec updated_at),
#       accessor en copie, disponible SANS Metrics ;
#   [3] partyline .lusers : rendu complet (valeurs + âge), état vide propre,
#       `.lusers refresh` envoie une requête immédiate (et resynchronise le
#       throttle périodique), refus propre si déconnecté ;
#   [4] aide partyline mise à jour ; marqueurs mb544.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::Partyline;

sub _slurp_741 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{
    package L741;
    sub new { bless { lines => [] }, shift }
    sub log { my ($self, $level, $msg) = @_; push @{ $self->{lines} }, [ $level, $msg ]; 1 }
    sub at_level { my ($self, $level) = @_; grep { $_->[0] == $level } @{ $self->{lines} } }
}

{
    package IRC741;
    sub new { bless { connected => 1, sent => [] }, shift }
    sub is_connected { $_[0]->{connected} }
    sub send_message {
        my ($self, @args) = @_;
        die "simulated LUSERS send failure\n" if $self->{fail};
        push @{ $self->{sent} }, \@args;
        1;
    }
}

{
    package Stream741;
    sub new { bless { out => '' }, shift }
    sub write { $_[0]->{out} .= $_[1]; 1 }
    sub out { $_[0]->{out} }
}

return sub {
    my ($assert) = @_;

    my $core_ok = eval { require Mediabot::Mediabot; 1 };
    if (!$core_ok) {
        $assert->ok(1, 'SKIP: Mediabot::Mediabot non chargeable ici');
        return;
    }

    # ------------------------------------------------------------------
    # [1] + [2] Log niveau 3 et cache cœur (sans Metrics)
    # ------------------------------------------------------------------
    my $logger = L741->new;
    my $core = bless { logger => $logger }, 'Mediabot';

    $core->update_network_metrics_from_numeric('251', [],
        'There are 7 users and 3 invisible on 2 servers');
    $core->update_network_metrics_from_numeric('266', [ '812', '1024' ], '');
    $core->update_network_metrics_from_numeric('252', [ '4' ], 'operator(s) online');
    $core->update_network_metrics_from_numeric('254', [ '128' ], 'channels formed');

    my @l3 = $logger->at_level(3);
    $assert->ok(@l3 == 4, 'log: une ligne niveau 3 par numeric utile');
    my ($l251) = grep { $_->[1] =~ /^LUSERS 251:/ } @l3;
    $assert->like(($l251->[1] || ''), qr/^LUSERS 251: servers=2 users=10$/,
        'log 251: paires cle=valeur triees');
    my ($l266) = grep { $_->[1] =~ /^LUSERS 266:/ } @l3;
    $assert->like(($l266->[1] || ''), qr/users=812 users_max=1024/,
        'log 266: current et max');

    $core->update_network_metrics_from_numeric('251', [], 'nothing useful');
    $assert->ok(scalar($logger->at_level(3)) == 4,
        'log: aucun bruit niveau 3 quand rien n\'est extrait');

    my $stats = $core->network_stats;
    $assert->ok($stats->{users} == 812 && $stats->{users_max} == 1024
        && $stats->{channels} == 128 && $stats->{servers} == 2
        && $stats->{operators} == 4,
        'cache: les cinq valeurs presentes SANS Metrics');
    $assert->ok(defined $stats->{updated_at}
        && abs(time() - $stats->{updated_at}) <= 5,
        'cache: updated_at recent');

    $stats->{users} = 1;
    $assert->ok($core->network_stats->{users} == 812, 'cache: accessor en copie');

    # ------------------------------------------------------------------
    # [3] Partyline .lusers
    # ------------------------------------------------------------------
    {
        my $irc = IRC741->new;
        $core->{irc} = $irc;
        my $party = bless { bot => $core }, 'Mediabot::Partyline';

        my $s = Stream741->new;
        $party->_cmd_lusers($s, 1, undef);
        $assert->like($s->out,
            qr/^Network: users=812 \(max 1024\) channels=128 servers=2 operators=4\r?$/m,
            'partyline: ligne reseau complete');
        $assert->like($s->out, qr/updated: \d+s ago/, 'partyline: age affiche');

        # refresh: envoi immediat + resynchronisation du throttle.
        $core->{network_lusers_last_request} = 0;
        my $s2 = Stream741->new;
        $party->_cmd_lusers($s2, 1, 'refresh');
        $assert->like($s2->out, qr/LUSERS refresh requested/, 'refresh: annonce');
        $assert->ok(@{ $irc->{sent} } == 1 && $irc->{sent}[0][0] eq 'LUSERS',
            'refresh: requete envoyee');
        $assert->ok(abs(time() - ($core->{network_lusers_last_request} || 0)) <= 5,
            'refresh: throttle periodique resynchronise');

        # deconnecte.
        $irc->{connected} = 0;
        my $s3 = Stream741->new;
        $party->_cmd_lusers($s3, 1, 'refresh');
        $assert->like($s3->out, qr/not sent \(not connected\)/, 'refresh: refus propre');

        # course de connexion: le test initial passe, l'envoi echoue ensuite.
        $irc->{connected} = 1;
        $irc->{fail} = 1;
        $core->{network_lusers_last_request} = 123;
        my $s3b = Stream741->new;
        $party->_cmd_lusers($s3b, 1, 'refresh');
        $assert->ok($core->{network_lusers_last_request} == 123,
            'refresh: echec envoi ne decale pas le throttle');
        $irc->{fail} = 0;

        # cache vide.
        my $empty = bless { logger => L741->new }, 'Mediabot';
        my $party2 = bless { bot => $empty }, 'Mediabot::Partyline';
        my $s4 = Stream741->new;
        $party2->_cmd_lusers($s4, 1, undef);
        $assert->like($s4->out, qr/none yet \(no LUSERS numerics received\)/,
            'partyline: etat vide propre');
    }

    # ------------------------------------------------------------------
    # [4] Aide et marqueurs
    # ------------------------------------------------------------------
    {
        my $party_src = _slurp_741(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
        $assert->like($party_src, qr/\.lusers \[refresh\]\s+- show network stats from LUSERS/,
            'aide: .lusers documente');
        $assert->like($party_src, qr/mb544-B1/, 'marqueur mb544 dans Partyline');

        my $core_src = _slurp_741(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
        $assert->like($core_src, qr/mb544-B1/, 'marqueur mb544 dans le coeur');
        $assert->like($core_src, qr/log\(3, "LUSERS \$numeric: \$detail"\)/,
            'coeur: details logges niveau 3');
        $assert->like($core_src, qr/log\(3, 'LUSERS refresh requested'\)/,
            'coeur: requete periodique loggee niveau 3');
    }
};
