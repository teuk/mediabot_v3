# t/cases/744_mb548_db_lag_hardening.t
# =============================================================================
# mb547 — diagnostic et blindage du « premier m check qui lag 10 s » (instance
# Undernet) : le pattern premier-hit-lent/suivants-ok pointe une connexion DB
# idle tuée en silence (wait_timeout/conntrack), payée par le premier humain.
#
# Trois volets contractés :
#   [1] DSN borné : mariadb_connect_timeout/read/write présents aux DEUX
#       sites de construction, clés mysql.*_TIMEOUT bornées (garbage/0 ->
#       défauts) ;
#   [2] ensure_connected chronométré : ping lent -> ligne niveau 3 avec
#       durée ; reconnexion -> durée logguée niveau 1 (ok/FAILED) ; chemin
#       rapide silencieux ;
#   [3] tick DB canonique : le health check A4 déjà présent reste l'unique
#       keepalive (pas de double ping ajouté) et synchronise le dbh legacy ;
#   [4] wrapper de chrono PRIVMSG : tout traitement > 1 s logge SLOW PRIVMSG
#       avec durée et origine (gardes statiques : wrapper + corps renommé +
#       une seule définition du corps) ;
#   [5] sample.conf documente les trois clés (contrat 615 déjà vert).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_744 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{
    package L744;
    sub new { bless { lines => [] }, shift }
    sub log { my ($self, $level, $msg) = @_; push @{ $self->{lines} }, [ $level, $msg ]; 1 }
    sub texts { map { $_->[1] } @{ $_[0]->{lines} } }
    sub at_level { my ($self, $level) = @_; grep { $_->[0] == $level } @{ $_[0]->{lines} } }
}

{
    # Faux dbh pilotable : ping ok / lent / mort.
    package DBH744;
    sub new { my ($class, %h) = @_; bless { %h }, $class }
    sub ping {
        my ($self) = @_;
        select(undef, undef, undef, $self->{ping_delay}) if $self->{ping_delay};
        return $self->{alive} ? 1 : 0;
    }
}

return sub {
    my ($assert) = @_;

    my $db_ok = eval { require Mediabot::DB; 1 };

    # ------------------------------------------------------------------
    # [1] Bornage des timeouts
    # ------------------------------------------------------------------
    if (!$db_ok) {
        $assert->ok(1, 'SKIP: Mediabot::DB non chargeable ici');
    }
    else {
        $assert->ok(Mediabot::DB::_bounded_timeout(undef, 5, 1, 60) == 5, 'timeout: absent -> defaut');
        $assert->ok(Mediabot::DB::_bounded_timeout('0', 5, 1, 60) == 5, 'timeout: 0 -> defaut');
        $assert->ok(Mediabot::DB::_bounded_timeout('12', 5, 1, 60) == 12, 'timeout: valeur gardee');
        $assert->ok(Mediabot::DB::_bounded_timeout('999', 5, 1, 60) == 60, 'timeout: plafonne');
        $assert->ok(Mediabot::DB::_bounded_timeout('abc', 5, 1, 60) == 5, 'timeout: garbage -> defaut');

        my $src = _slurp_744(File::Spec->catfile('Mediabot', 'DB.pm'));
        my $dsn_sites = () = $src =~ /mariadb_connect_timeout=\$t_connect/g;
        $assert->ok($dsn_sites == 2, 'DSN: les DEUX sites de construction bornes');
        $assert->like($src, qr/mariadb_read_timeout=\$t_read/, 'DSN: read timeout');
        $assert->like($src, qr/mariadb_write_timeout=\$t_write/, 'DSN: write timeout');
    }

    # ------------------------------------------------------------------
    # [2] ensure_connected chronométré
    # ------------------------------------------------------------------
    if ($db_ok) {
        # Chemin rapide: silencieux.
        my $log_fast = L744->new;
        my $fast = bless { dbh => DBH744->new(alive => 1), logger => $log_fast }, 'Mediabot::DB';
        my $h = $fast->ensure_connected;
        $assert->ok($h && !scalar($log_fast->texts), 'rapide: aucun log');

        # Ping lent (>0.25s): ligne niveau 3 avec duree.
        my $log_slow = L744->new;
        my $slow = bless { dbh => DBH744->new(alive => 1, ping_delay => 0.3),
                           logger => $log_slow }, 'Mediabot::DB';
        $slow->ensure_connected;
        my ($l3) = $log_slow->at_level(3);
        $assert->like(($l3->[1] || ''), qr/^DB ping slow: 0\.\d+s/,
            'lent: duree logguee niveau 3');

        # Connexion morte: reconnect tente (echouera sans conf), duree niveau 1.
        my $log_dead = L744->new;
        my $dead = bless { dbh => DBH744->new(alive => 0), logger => $log_dead,
                           conf => undef }, 'Mediabot::DB';
        my $dead_ret = eval { $dead->ensure_connected };
        my @l1 = $log_dead->at_level(1);
        $assert->ok((grep { $_->[1] =~ /DB connection lost/ } @l1) == 1,
            'mort: perte annoncee');
        $assert->ok(!defined($dead_ret),
            'mort: aucun ancien handle mort retourne apres echec');
        $assert->ok((grep { $_->[1] =~ /DB reconnect FAILED in \d+\.\d+s \(ping wait was \d+\.\d+s\)/ } @l1) == 1,
            'mort: echec de reconnexion nomme correctement avec les durees');
    }

    # ------------------------------------------------------------------
    # [3]+[4] Gardes statiques : tick DB unique + wrapper PRIVMSG
    # ------------------------------------------------------------------
    {
        my $src = _slurp_744('mediabot.pl');
        my $tick_db_checks = () = $src =~ /my \$live_dbh = eval \{ \$mediabot->\{db\}->ensure_connected\(\) \};/g;
        $assert->ok($tick_db_checks == 1,
            'tick: un seul health check DB canonique');
        $assert->unlike($src, qr/db_keepalive/,
            'tick: aucun second keepalive redondant');
        $assert->like($src, qr/SLOW PRIVMSG: processing took/,
            'wrapper: message de lenteur present');
        $assert->like($src, qr/sub on_message_PRIVMSG \{[^}]*_on_message_PRIVMSG_body/s,
            'wrapper: delegue au corps renomme');
        my $body_defs = () = $src =~ /^sub _on_message_PRIVMSG_body \{/mg;
        $assert->ok($body_defs == 1, 'wrapper: corps defini une seule fois');
        $assert->like($src, qr/tv_interval\(\$t0_548\)/, 'wrapper: chrono HiRes reel');
        $assert->like($src, qr/my \$want_547 = wantarray;/,
            'wrapper: contexte appelant capture avant delegation');
        $assert->like($src, qr/return \$want_547 \? \@ret_547 : \$ret_547;/,
            'wrapper: contexte scalaire ou liste preserve');
    }

    # ------------------------------------------------------------------
    # [5] sample.conf
    # ------------------------------------------------------------------
    {
        my $sample = _slurp_744('mediabot.sample.conf');
        for my $k (qw(CONNECT_TIMEOUT READ_TIMEOUT WRITE_TIMEOUT)) {
            $assert->like($sample, qr/^#$k=\d+/m, "sample: $k documente");
        }
    }
};
