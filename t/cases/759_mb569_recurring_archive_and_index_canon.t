# t/cases/759_mb569_recurring_archive_and_index_canon.t
# =============================================================================
# mb569 — trois volets :
#
# A. archive_channel_log() — archivage quotidien vers la base jumelle :
#   [1] desactive proprement sans ARCHIVE_DBNAME (retour 0, aucune requete) ;
#       nom de base invalide -> refus loggue ;
#   [2] flux atomique-par-lot : CREATE IF NOT EXISTS (schema LIKE), SELECT
#       des ids eligibles (predicat « ts < NOW()-N DAY » = rattrapage offline
#       par construction), INSERT IGNORE, VERIFICATION count == lot AVANT le
#       DELETE ; verification en echec -> lot abandonne, RIEN de supprime,
#       retentera au run suivant ;
#   [3] bornes : jours 1..3650, MAX_PER_RUN 5000..2000000, events valides
#       [a-z_] uniquement, Config::Simple ARRAY ref gere ;
#   [4] cablage : tache scheduler 'channel_log_archive' interval 86400 avant
#       channel_log_purge ; les 4 clefs documentees dans sample.conf ;
#       aucun backtick apparie dans le sub (audit securite).
#
# B. tools/normalize_channel_log_indexes.pl :
#   [5] existe, compile, moule conf identique, dry-run par defaut, canon
#       des 4 index, DROP calcule sur l'etat PROJETE (nick tombe des que
#       (nick,event_type) est planifie), hors-canon -> REVIEW jamais droppe.
#
# C. Regression du detecteur (incident strict refs) :
#   [6] plus AUCUNE boucle « for my $a/$b » dans les deux outils d'index —
#       le shadowing de $a/$b casse les sort() interieurs.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::Mediabot;

sub _slurp_759 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{
    package L759;
    sub new { bless { lines => [] }, shift }
    sub log { my ($self, $lvl, $msg) = @_; push @{ $self->{lines} }, [ $lvl, $msg ]; 1 }
    sub grep_msg { my ($self, $re) = @_; grep { $_->[1] =~ $re } @{ $_[0]->{lines} } }
}

{
    package Conf759;
    sub new { my ($class, %kv) = @_; bless { %kv }, $class }
    sub get { my ($self, $k) = @_; return $self->{$k} }
}

{
    # Fake DBH scriptable : journalise do/prepare, pilote les resultats.
    package DBH759;
    sub new {
        my ($class, %h) = @_;
        return bless { done => [], ids_batches => $h{ids_batches} // [],
                       verify_count => $h{verify_count}, errstr => undef,
                       fail_do => $h{fail_do} // {}, }, $class;
    }
    sub errstr { $_[0]{errstr} }
    sub do {
        my ($self, $sql, undef, @bind) = @_;
        push @{ $self->{done} }, [ $sql, [ @bind ] ];
        if (my ($frag) = grep { index($sql, $_) >= 0 } keys %{ $self->{fail_do} }) {
            $self->{errstr} = $self->{fail_do}{$frag};
            die "do failed\n";
        }
        return 1;
    }
    sub selectrow_array {
        my ($self, $sql, undef, @bind) = @_;
        push @{ $self->{done} }, [ $sql, [ @bind ] ];
        my $vc = $self->{verify_count};
        return ref($vc) eq 'CODE' ? $vc->(scalar @bind) : ($vc // scalar @bind);
    }
    sub prepare {
        my ($self, $sql) = @_;
        return DBSTH759->new($self, $sql);
    }

    package DBSTH759;
    sub new { my ($class, $dbh, $sql) = @_; bless { dbh => $dbh, sql => $sql }, $class }
    sub execute {
        my ($self, @bind) = @_;
        push @{ $self->{dbh}{done} }, [ $self->{sql}, [ @bind ] ];
        $self->{batch} = shift @{ $self->{dbh}{ids_batches} } // [];
        $self->{i} = 0;
        return 1;
    }
    sub fetchrow_array {
        my ($self) = @_;
        return () if $self->{i} >= scalar @{ $self->{batch} };
        return ($self->{batch}[ $self->{i}++ ]);
    }
    sub finish { 1 }
}

sub _bot_759 {
    my (%h) = @_;
    return bless {
        conf   => $h{conf},
        logger => ($h{logger} // L759->new),
        dbh    => $h{dbh},
        db     => undef,
    }, 'Mediabot';
}

return sub {
    my ($assert) = @_;

    # ------------------------------------------------------------------
    # [1] Desactive / invalide
    # ------------------------------------------------------------------
    {
        my $dbh = DBH759->new;
        my $bot = _bot_759(conf => Conf759->new, dbh => $dbh);
        $assert->ok($bot->archive_channel_log == 0 && !@{ $dbh->{done} },
            'sans ARCHIVE_DBNAME: desactive, aucune requete');

        my $logger = L759->new;
        my $bad = _bot_759(dbh => DBH759->new, logger => $logger,
            conf => Conf759->new('mysql.CHANNEL_LOG_ARCHIVE_DBNAME' => 'bad-name!'));
        $assert->ok($bad->archive_channel_log == 0
            && scalar($logger->grep_msg(qr/invalid ARCHIVE_DBNAME/)) == 1,
            'nom de base invalide: refus loggue');
    }

    # ------------------------------------------------------------------
    # [2] Flux nominal + verification en echec
    # ------------------------------------------------------------------
    {
        my $dbh = DBH759->new(ids_batches => [ [ 1, 2, 3 ], [] ]);
        my $bot = _bot_759(dbh => $dbh,
            conf => Conf759->new('mysql.CHANNEL_LOG_ARCHIVE_DBNAME' => 'mediabot2'));
        my $moved = $bot->archive_channel_log;
        $assert->ok($moved == 3, 'nominal: 3 lignes deplacees');

        my @sql = map { $_->[0] } @{ $dbh->{done} };
        my ($i_create) = grep { $sql[$_] =~ /CREATE TABLE IF NOT EXISTS mediabot2\.CHANNEL_LOG_ARCHIVE LIKE CHANNEL_LOG/ } 0..$#sql;
        my ($i_sel)    = grep { $sql[$_] =~ /SELECT id_channel_log FROM CHANNEL_LOG/ } 0..$#sql;
        my ($i_ins)    = grep { $sql[$_] =~ /INSERT IGNORE INTO mediabot2\.CHANNEL_LOG_ARCHIVE/ } 0..$#sql;
        my ($i_ver)    = grep { $sql[$_] =~ /SELECT COUNT\(\*\) FROM mediabot2\.CHANNEL_LOG_ARCHIVE arch/ } 0..$#sql;
        my ($i_del)    = grep { $sql[$_] =~ /DELETE FROM CHANNEL_LOG WHERE id_channel_log IN/ } 0..$#sql;
        $assert->ok(defined $i_create && defined $i_ins && defined $i_ver && defined $i_del
            && $i_create < $i_sel && $i_sel < $i_ins && $i_ins < $i_ver && $i_ver < $i_del,
            'ordre strict: CREATE -> SELECT -> INSERT -> VERIFY -> DELETE');
        $assert->like($sql[$i_sel], qr/ts < DATE_SUB\(NOW\(\), INTERVAL \? DAY\)/,
            'predicat en age (rattrapage offline par construction)');

        # Verification en echec -> rien supprime
        my $dbh2 = DBH759->new(ids_batches => [ [ 10, 11 ] ], verify_count => 1);
        my $log2 = L759->new;
        my $bot2 = _bot_759(dbh => $dbh2, logger => $log2,
            conf => Conf759->new('mysql.CHANNEL_LOG_ARCHIVE_DBNAME' => 'mediabot2'));
        my $moved2 = $bot2->archive_channel_log;
        my @del2 = grep { $_->[0] =~ /DELETE FROM CHANNEL_LOG/ } @{ $dbh2->{done} };
        $assert->ok($moved2 == 0 && !@del2
            && scalar($log2->grep_msg(qr/batch aborted .*nothing lost/)) == 1,
            'verify en echec: lot abandonne, AUCUN DELETE, retentera');
    }

    # ------------------------------------------------------------------
    # [3] Bornes et Config::Simple ARRAY
    # ------------------------------------------------------------------
    {
        my $dbh = DBH759->new(ids_batches => [ [] ]);
        my $bot = _bot_759(dbh => $dbh, conf => Conf759->new(
            'mysql.CHANNEL_LOG_ARCHIVE_DBNAME' => 'mediabot2',
            'mysql.CHANNEL_LOG_ARCHIVE_PRESENCE_DAYS' => 99999,
            'mysql.CHANNEL_LOG_ARCHIVE_EVENTS' => [ 'join', 'quit' ],
        ));
        $bot->archive_channel_log;
        my ($sel) = grep { $_->[0] =~ /SELECT id_channel_log/ } @{ $dbh->{done} };
        $assert->ok($sel && $sel->[1][0] == 3650, 'jours bornes a 3650');
        $assert->ok(scalar(@{ $sel->[1] }) == 3, 'ARRAY ref Config::Simple gere (2 events)');

        my $log3 = L759->new;
        my $none = _bot_759(dbh => DBH759->new, logger => $log3, conf => Conf759->new(
            'mysql.CHANNEL_LOG_ARCHIVE_DBNAME' => 'mediabot2',
            'mysql.CHANNEL_LOG_ARCHIVE_EVENTS' => 'INVALID!, ALSO BAD',
        ));
        $assert->ok($none->archive_channel_log == 0
            && scalar($log3->grep_msg(qr/no valid event/)) == 1,
            'events tous invalides: refus loggue');
    }

    # ------------------------------------------------------------------
    # [4] Cablage
    # ------------------------------------------------------------------
    {
        my $main_src = _slurp_759('mediabot.pl');
        $assert->like($main_src,
            qr/name\s+=> 'channel_log_archive',\n\s+interval\s+=> 86400,/,
            'tache scheduler quotidienne');
        $assert->like($main_src, qr/start_channel_log_archive_async/,
            'scheduler: archivage lance hors boucle IRC');
        my $pos_arch = index($main_src, "'channel_log_archive'");
        my $pos_purge = index($main_src, "'channel_log_purge'");
        $assert->ok($pos_arch > -1 && $pos_purge > $pos_arch,
            'archive enregistree avant purge');

        my $sample = _slurp_759('mediabot.sample.conf');
        for my $k (qw(CHANNEL_LOG_ARCHIVE_DBNAME CHANNEL_LOG_ARCHIVE_PRESENCE_DAYS
                      CHANNEL_LOG_ARCHIVE_EVENTS CHANNEL_LOG_ARCHIVE_MAX_PER_RUN)) {
            $assert->like($sample, qr/^#\Q$k\E=/m, "sample.conf: $k");
        }

        my $mod_src = _slurp_759(File::Spec->catfile('Mediabot', 'Mediabot.pm'));
        my ($sub_src) = $mod_src =~ /(sub archive_channel_log \{.*?\n\})/s;
        $assert->ok(defined $sub_src && $sub_src !~ /`[^`\n]+`/,
            'archive_channel_log: aucun backtick apparie (audit securite)');
        $assert->like($sub_src, qr/GRANTs on \$adb/, 'echec CREATE: le message pointe les GRANTs');
    }

    # ------------------------------------------------------------------
    # [5] Outil normalize
    # ------------------------------------------------------------------
    {
        my $path = File::Spec->catfile('tools', 'normalize_channel_log_indexes.pl');
        $assert->ok(-f $path && system($^X, '-c', $path) == 0, 'normalize: existe et compile');
        my $src = _slurp_759($path);
        $assert->like($src, qr/mysql\.MAIN_PROG_DDBNAME/, 'normalize: moule conf');
        $assert->like($src, qr/DRY-RUN .* rien ne sera modifie/, 'normalize: dry-run par defaut');
        for my $canon ('id_channel', 'nick', 'event_type', 'ts') {
            $assert->like($src, qr/'\Q$canon\E'/, "normalize: canon contient $canon");
        }
        $assert->like($src, qr/etat PROJETE/, 'normalize: DROP calcule sur l\'etat projete');
        $assert->like($src, qr/REVIEW/, 'normalize: hors canon = review, pas de drop auto');
        $assert->like($src, qr/measure_channel_log\.pl/, 'normalize: renvoie vers measure');
    }

    # ------------------------------------------------------------------
    # [6] Regression $a/$b
    # ------------------------------------------------------------------
    {
        for my $tool ('analyze_channel_log.pl', 'normalize_channel_log_indexes.pl') {
            my $src = _slurp_759(File::Spec->catfile('tools', $tool));
            $assert->unlike($src, qr/for my \$[ab] \(/,
                "$tool: aucune boucle for my \$a/\$b (shadowing du sort)");
        }
    }
};
