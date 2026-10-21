package Mediabot::ChannelLog::Reader;

use strict;
use warnings;
use utf8;
use Exporter 'import';

our @EXPORT_OK = qw(channel_log_archive_table channel_log_sources channel_log_gather);

# Read existing live/archive tables through caller-owned database handles.
# Query templates, bindings, row merging and user-facing output belong to callers.
# Loading this module does not load Helpers, connect to a database or run SQL.

# mb570-B1: table d'archive CHANNEL_LOG si configuree (mb569), sinon undef.
# Nom valide uniquement — memes regles que archive_channel_log.
sub channel_log_archive_table {
    my ($self) = @_;
    my $adb = eval { $self->{conf}->get('mysql.CHANNEL_LOG_ARCHIVE_DBNAME') } // '';
    $adb = '' if ref $adb;
    return undef unless length $adb && $adb =~ /\A[A-Za-z0-9_]{1,64}\z/;
    return "$adb.CHANNEL_LOG_ARCHIVE";
}

# mb576-B1: le pattern UNION ALL de mb574/575 est REMPLACE par des requetes
# par table + fusion Perl (analyse ChatGPT validee : les WHERE sont pousses
# dans les branches d'une derivee, mais PAS les ORDER BY/LIMIT — un
# « m last » sur un gros parleur materialisait toutes ses lignes pour en
# garder une, et meme les COUNT materialisent avant d'agreger). Chaque
# petite requete par table utilise SES index, rien n'est materialise.
# mb577-B1: l'archive n'est jointe que si elle peut CONTENIR les donnees
# demandees (revue pre-commit) : avec CONTENT_DAYS=0 (conf Undernet), elle ne
# recoit que la presence — les commandes de contenu n'ont rien a y chercher.
#   scope 'content'  -> archive jointe si CHANNEL_LOG_ARCHIVE_CONTENT_DAYS  > 0
#   scope 'presence' -> archive jointe si CHANNEL_LOG_ARCHIVE_PRESENCE_DAYS > 0
#   scope 'all'      -> archive jointe si au moins une politique est active
sub channel_log_sources {
    my ($self, $scope) = @_;
    $scope ||= 'all';
    # Keep late-bound Helpers overrides when used through the compatibility API.
    my $archive = defined &Mediabot::Helpers::channel_log_archive_table
        ? Mediabot::Helpers::channel_log_archive_table($self)
        : channel_log_archive_table($self);
    return ('CHANNEL_LOG') unless $archive;
    my $p_days = int(eval { $self->{conf}->get('mysql.CHANNEL_LOG_ARCHIVE_PRESENCE_DAYS') } // 7);
    my $c_days = int(eval { $self->{conf}->get('mysql.CHANNEL_LOG_ARCHIVE_CONTENT_DAYS') } // 0);
    my $join =
          $scope eq 'content'  ? ($c_days > 0)
        : $scope eq 'presence' ? ($p_days > 0)
        :                        ($c_days > 0 || $p_days > 0);
    return $join ? ('CHANNEL_LOG', $archive) : ('CHANNEL_LOG');
}

# Execute le MEME SQL sur chaque source (le token litteral __CLSRC__ est
# remplace par le nom de table — pas de sprintf: les SQL peuvent contenir
# des % de DATE_FORMAT). $row_cb recoit chaque ligne (hashref) et la source.
#
# mb577-B1: contrat vide/panne de la revue pre-commit — zero ligne est un
# SUCCES SQL valide ; seule la table ACTIVE conditionne le succes de la
# commande ; l'archive reste best-effort mais son echec est LOGUE (jamais
# silencieux). Retour: hashref
#   { live_ok, sources, executed, ok_sources, rows, tainted }
# live_ok=1 si le resultat est exploitable : le vif a termine correctement
# et aucune erreur de fetch archive n'a deja injecte des lignes partielles
# dans le callback. tainted=1 signale ce dernier cas fail-closed.
sub channel_log_gather {
    my ($self, $dbh, $sql_tpl, $bind, $row_cb, $scope) = @_;
    my @sources = defined &Mediabot::Helpers::channel_log_sources
        ? Mediabot::Helpers::channel_log_sources($self, $scope)
        : channel_log_sources($self, $scope);
    my %st = ( live_ok => 0, sources => scalar @sources,
               executed => 0, ok_sources => 0, rows => 0, tainted => 0 );
    for my $src (@sources) {
        my $is_live = ($src eq 'CHANNEL_LOG') ? 1 : 0;
        (my $sql = $sql_tpl) =~ s/__CLSRC__/$src/g;
        $st{executed}++;
        my $sth = eval { $dbh->prepare($sql) };
        my $ok  = $sth && eval { $sth->execute(@{ $bind || [] }) };
        unless ($ok) {
            my $err = $@ || (eval { $dbh->errstr } // 'unknown');
            if ($is_live) {
                # mb578-B1: la commande devra de toute facon refuser le
                # resultat — arret IMMEDIAT, l'archive (potentiellement
                # une requete historique couteuse) n'est jamais tentee.
                eval { $self->{logger}->log(0, "channel_log_gather: LIVE query failed: $err") };
                last;
            }
            eval { $self->{logger}->log(1, "channel_log_gather: archive $src failed (live result kept): $err") };
            next;
        }
        my $source_rows = 0;
        while (my $r = $sth->fetchrow_hashref) {
            $source_rows++;
            $st{rows}++;
            $row_cb->($r, $src);
        }
        # mb578-B1: une fin de lecture peut etre une ERREUR de fetch et non
        # une fin normale — DBI l'expose via $sth->err apres la boucle.
        my $fetch_err = eval { $sth->err };
        my $fetch_errstr = eval { $sth->errstr } || $fetch_err || 'unknown';
        eval { $sth->finish };
        if ($fetch_err) {
            if ($is_live) {
                eval { $self->{logger}->log(0,
                    "channel_log_gather: LIVE fetch failed: $fetch_errstr") };
                last;
            }
            if ($source_rows > 0) {
                # mb579-B1: les callbacks ont deja absorbe une partie de
                # l'archive. On ne peut plus promettre « live result kept » :
                # le resultat est contamine et la commande doit echouer.
                $st{tainted} = 1;
                $st{live_ok} = 0;
                eval { $self->{logger}->log(0,
                    "channel_log_gather: archive $src fetch failed after "
                    . "$source_rows row(s); partial result tainted, command aborted: "
                    . $fetch_errstr) };
                last;
            }
            eval { $self->{logger}->log(1,
                "channel_log_gather: archive $src fetch failed before any row "
                . "(live result kept): $fetch_errstr") };
            next;
        }
        $st{ok_sources}++;
        $st{live_ok} = 1 if $is_live;
    }
    return \%st;
}

1;
