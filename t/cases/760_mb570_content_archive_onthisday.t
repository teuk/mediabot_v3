# t/cases/760_mb570_content_archive_onthisday.t
# =============================================================================
# mb570 — l'action de masse sur le vieux public devient possible SANS amputer
# la memoire du canal :
#   [1] archive_channel_log a DEUX politiques : presence (PRESENCE_DAYS,
#       defaut 7) toujours, contenu (CONTENT_DAYS, defaut 0 = OFF) en opt-in
#       explicite ; budget MAX_PER_RUN partage entre les deux ;
#   [2] Helpers::channel_log_archive_table : nom valide -> table, invalide ou
#       absent -> undef ;
#   [3] _onthisday_lines fusionne VIF + ARCHIVE par annee (msgs sommes,
#       people max, source memorisee) ; top nick et citation d'epoque lus
#       depuis la ou les tables ou vit l'annee ; archive absente ->
#       comportement historique exact (best-effort, aucune erreur) ;
#   [4] sample.conf documente les 2 nouvelles cles (contrat 397/615).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::Mediabot;
use Mediabot::Helpers;

sub _slurp_760 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{
    package L760;
    sub new { bless { lines => [] }, shift }
    sub log { 1 }
}

{
    package Conf760;
    sub new { my ($class, %kv) = @_; bless { %kv }, $class }
    sub get { my ($self, $k) = @_; return $self->{$k} }
}

{
    package DBH760;
    sub new {
        my ($class, %h) = @_;
        return bless { done => [], ids_batches => $h{ids_batches} // [],
                       tables => $h{tables} // {} }, $class;
    }
    sub errstr { undef }
    sub do { my ($self, $sql, undef, @bind) = @_; push @{ $self->{done} }, [ $sql, [ @bind ] ]; 1 }
    sub selectrow_array {
        my ($self, $sql, undef, @bind) = @_;
        push @{ $self->{done} }, [ $sql, [ @bind ] ];
        return scalar @bind;
    }
    sub prepare { my ($self, $sql) = @_; return STH760->new($self, $sql) }

    package STH760;
    sub new { my ($class, $dbh, $sql) = @_; bless { dbh => $dbh, sql => $sql }, $class }
    sub execute {
        my ($self, @bind) = @_;
        push @{ $self->{dbh}{done} }, [ $self->{sql}, [ @bind ] ];
        if ($self->{sql} =~ /SELECT id_channel_log/) {
            $self->{rows} = [ map { [ $_ ] } @{ shift @{ $self->{dbh}{ids_batches} } // [] } ];
        }
        else {
            # table pilotee : la premiere cle de {tables} contenue dans le SQL
            my ($t) = grep { index($self->{sql}, $_) >= 0 } keys %{ $self->{dbh}{tables} };
            my $spec = $t ? $self->{dbh}{tables}{$t} : undef;
            my $kind = $self->{sql} =~ /YEAR\(ts\)\s+AS y/ ? 'years'
                     : $self->{sql} =~ /GROUP BY nick/     ? 'topnick'
                     :                                        'quote';
            $self->{rows} = [ map { [ @$_ ] } @{ ($spec && $spec->{$kind}) || [] } ];
        }
        $self->{i} = 0;
        return 1;
    }
    sub fetchrow_array {
        my ($self) = @_;
        return () if $self->{i} >= scalar @{ $self->{rows} };
        return @{ $self->{rows}[ $self->{i}++ ] };
    }
    sub fetchrow_hashref {
        my ($self) = @_;
        return undef if $self->{i} >= scalar @{ $self->{rows} };
        my $r = $self->{rows}[ $self->{i}++ ];
        if ($self->{sql} =~ /YEAR\(ts\)\s+AS y/) {
            return { y => $r->[0], msgs => $r->[1], people => $r->[2] };
        }
        if ($self->{sql} =~ /GROUP BY nick/) {
            return { nick => $r->[0], c => $r->[1] };
        }
        return { nick => $r->[0], publictext => $r->[1] };
    }
    sub finish { 1 }
}

return sub {
    my ($assert) = @_;

    # ------------------------------------------------------------------
    # [1] Deux politiques, budget partage
    # ------------------------------------------------------------------
    {
        # Contenu OFF par defaut : une seule politique interrogee.
        my $dbh = DBH760->new(ids_batches => [ [] ]);
        my $bot = bless { conf => Conf760->new(
            'mysql.CHANNEL_LOG_ARCHIVE_DBNAME' => 'mediabot2'),
            logger => L760->new, dbh => $dbh, db => undef }, 'Mediabot';
        $bot->archive_channel_log;
        my @sels = grep { $_->[0] =~ /SELECT id_channel_log/ } @{ $dbh->{done} };
        $assert->ok(scalar(@sels) == 1, 'contenu OFF par defaut: une seule politique');
        $assert->ok($sels[0][1][0] == 7, 'presence: 7 jours par defaut');

        # Contenu ON : deux politiques, presence d'abord, jours respectifs.
        my $dbh2 = DBH760->new(ids_batches => [ [], [] ]);
        my $bot2 = bless { conf => Conf760->new(
            'mysql.CHANNEL_LOG_ARCHIVE_DBNAME' => 'mediabot2',
            'mysql.CHANNEL_LOG_ARCHIVE_CONTENT_DAYS' => 730),
            logger => L760->new, dbh => $dbh2, db => undef }, 'Mediabot';
        $bot2->archive_channel_log;
        my @sels2 = grep { $_->[0] =~ /SELECT id_channel_log/ } @{ $dbh2->{done} };
        $assert->ok(scalar(@sels2) == 2, 'contenu ON: deux politiques');
        $assert->ok($sels2[0][1][0] == 7 && $sels2[1][1][0] == 730,
            'presence 7j puis contenu 730j');
        my @ev2 = @{ $sels2[1][1] };
        $assert->ok((grep { $_ eq 'public' } @ev2) && (grep { $_ eq 'action' } @ev2),
            'contenu: events public/action par defaut');
    }

    # ------------------------------------------------------------------
    # [2] Helper table d'archive
    # ------------------------------------------------------------------
    {
        my $ok_bot  = { conf => Conf760->new('mysql.CHANNEL_LOG_ARCHIVE_DBNAME' => 'mediabot2') };
        my $bad_bot = { conf => Conf760->new('mysql.CHANNEL_LOG_ARCHIVE_DBNAME' => 'bad-db!') };
        my $off_bot = { conf => Conf760->new };
        $assert->is(Mediabot::Helpers::channel_log_archive_table($ok_bot),
            'mediabot2.CHANNEL_LOG_ARCHIVE', 'helper: nom valide -> table');
        $assert->ok(!defined Mediabot::Helpers::channel_log_archive_table($bad_bot),
            'helper: nom invalide -> undef');
        $assert->ok(!defined Mediabot::Helpers::channel_log_archive_table($off_bot),
            'helper: non configure -> undef');
    }

    # ------------------------------------------------------------------
    # [3] onthisday : fusion vif + archive
    # ------------------------------------------------------------------
    {
        # Vif: 2026 seulement. Archive: 2019 et 2020. Top nicks distincts.
        my $tables = {
            'FROM CHANNEL_LOG' => {
                years   => [ [ 2026, 10, 4 ] ],
                topnick => [ [ 'Recent', 6 ] ],
                quote   => [ [ 'Recent', 'une phrase vive assez longue pour la fenetre de citation' ] ],
            },
            'mediabot2.CHANNEL_LOG_ARCHIVE' => {
                years   => [ [ 2020, 50, 9 ], [ 2019, 30, 7 ] ],
                topnick => [ [ 'Ancien', 20 ] ],
                quote   => [ [ 'Ancien', 'une phrase memorable d\'epoque pour la citation' ] ],
            },
        };
        my $dbh = DBH760->new(tables => $tables);
        my $bot = bless { conf => Conf760->new(
            'mysql.CHANNEL_LOG_ARCHIVE_DBNAME' => 'mediabot2'),
            logger => L760->new, dbh => $dbh }, 'Mediabot';

        my @lines = Mediabot::UserCommands::_onthisday_lines($bot, 5, '#quebec');
        my $head = $lines[0] // '';
        $assert->like($head, qr/\(2019-2026\): 90 message\(s\) across 3 year\(s\)/,
            'fusion: 3 annees, 90 messages, span 2019-2026');
        my $joined = join("\n", @lines);
        $assert->like($joined, qr/2026: 10 msg.*Recent/s, 'annee vive: top nick du vif');
        $assert->like($joined, qr/2020: 50 msg.*Ancien/s, 'annee archivee: top nick de l\'archive');
        $assert->like($joined, qr/From 2026 .* <Recent>/, 'citation de l\'annee la plus recente, depuis SA table');

        # Sans archive configuree : uniquement le vif, aucune requete archive.
        my $dbh_solo = DBH760->new(tables => { 'FROM CHANNEL_LOG' => $tables->{'FROM CHANNEL_LOG'} });
        my $solo = bless { conf => Conf760->new, logger => L760->new, dbh => $dbh_solo }, 'Mediabot';
        my @solo_lines = Mediabot::UserCommands::_onthisday_lines($solo, 5, '#quebec');
        $assert->like(($solo_lines[0] // ''), qr/\(2026\): 10 message/,
            'sans archive: comportement historique');
        my @arch_q = grep { $_->[0] =~ /CHANNEL_LOG_ARCHIVE/ } @{ $dbh_solo->{done} };
        $assert->ok(!@arch_q, 'sans archive: aucune requete vers l\'archive');
    }

    # ------------------------------------------------------------------
    # [4] sample.conf
    # ------------------------------------------------------------------
    {
        my $sample = _slurp_760('mediabot.sample.conf');
        for my $k (qw(CHANNEL_LOG_ARCHIVE_CONTENT_DAYS CHANNEL_LOG_ARCHIVE_CONTENT_EVENTS)) {
            $assert->like($sample, qr/^#\Q$k\E=/m, "sample.conf: $k");
        }
    }
};
