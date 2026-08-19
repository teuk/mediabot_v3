# t/cases/765_mb576_archive_career_completeness.t
# =============================================================================
# mb576 — le contrat per-table + fusion Perl, sur TOUTE la surface carriere.
# Analyse (creditee) : dans une derivee UNION ALL, MariaDB pousse les WHERE
# dans les branches mais PAS les ORDER BY/LIMIT ; un « m last » d'un gros
# parleur materialisait toutes ses lignes pour en garder une. Le modele
# correct etait celui de mb570 (onthisday) : une petite requete par table,
# chaque branche sert SES index, la fusion se fait en Perl.
#   [1] helpers unitaires : channel_log_sources (1 ou 2 sources) et
#       channel_log_gather (substitution __CLSRC__, best-effort par source,
#       bind transmis, callback par ligne) ;
#   [2] les 12 subs carriere utilisent le gather ;
#   [3] garde globale : aucun UNION ALL dans du SQL reel du fichier ;
#   [4] fusion a cheval : un nick present en vif ET en archive compte sa
#       SOMME dans les rangs (l'ancien HAVING par branche l'aurait sous-
#       estime) — verifie sur une fixture a deux sources ;
#   [5] les fenetres recentes (sparkline dashboard, taux milestone) restent
#       en CHANNEL_LOG dur.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_765 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

sub _sub_src_765 {
    my ($src, $name) = @_;
    my ($body) = $src =~ /(sub \Q$name\E \{.*?\n\})/s;
    return $body;
}

# Fixture DBH minimal : prepare/execute/fetchrow_hashref sur des jeux de
# lignes par table, pour exercer channel_log_gather sans MariaDB.
package Mb576::FakeSth;
sub new { my ($c,$rows)=@_; bless { rows => [@$rows], binds => undef }, $c }
sub execute { my ($self,@b)=@_; $self->{binds} = [@b]; 1 }
sub fetchrow_hashref { my ($self)=@_; shift @{ $self->{rows} } }
sub finish { 1 }

package Mb576::FakeDbh;
sub new { my ($c,%by_sql)=@_; bless { by_sql => \%by_sql, seen => [] }, $c }
sub prepare {
    my ($self,$sql)=@_;
    push @{ $self->{seen} }, $sql;
    for my $tbl (sort keys %{ $self->{by_sql} }) {
        return Mb576::FakeSth->new($self->{by_sql}{$tbl}) if index($sql, $tbl) >= 0;
    }
    return Mb576::FakeSth->new([]);
}

package main;

return sub {
    my ($assert) = @_;

    require Mediabot::Helpers;

    # [1a] sources : sans archive -> vif seul ; avec -> vif + annexe
    my $bot_noarch = { conf => undef };
    {
        no warnings 'redefine';
        local *Mediabot::Helpers::channel_log_archive_table = sub { undef };
        my @src = Mediabot::Helpers::channel_log_sources($bot_noarch);
        $assert->is(join(',', @src), 'CHANNEL_LOG',
            'sources: vif seul sans archive');
    }
    {
        no warnings 'redefine';
        local *Mediabot::Helpers::channel_log_archive_table
            = sub { 'mediabot2.CHANNEL_LOG_ARCHIVE' };
        my @src = Mediabot::Helpers::channel_log_sources($bot_noarch);
        $assert->is(join(',', @src),
            'CHANNEL_LOG,mediabot2.CHANNEL_LOG_ARCHIVE',
            'sources: vif + annexe avec archive');

        # [1b] gather : substitution __CLSRC__, bind transmis, lignes des
        # deux sources livrees au callback
        my $dbh = Mb576::FakeDbh->new(
            'FROM CHANNEL_LOG '            => [ { nick => 'SlaY', cnt => 300 } ],
            'FROM mediabot2.CHANNEL_LOG_ARCHIVE ' => [ { nick => 'SlaY', cnt => 800 },
                                                       { nick => 'aur',  cnt => 900 } ],
        );
        my %counts;
        Mediabot::Helpers::channel_log_gather($bot_noarch, $dbh,
            'SELECT nick, COUNT(*) AS cnt FROM __CLSRC__ cl WHERE c.name = ? GROUP BY nick',
            [ '#quebec' ],
            sub { $counts{ $_[0]->{nick} } += $_[0]->{cnt} });
        $assert->is(scalar @{ $dbh->{seen} }, 2, 'gather: une requete par source');
        $assert->ok($dbh->{seen}[0] !~ /__CLSRC__/ && $dbh->{seen}[1] !~ /__CLSRC__/,
            'gather: token __CLSRC__ substitue partout');

        # [4] fusion a cheval : SlaY = 300 (vif) + 800 (archive) = 1100
        $assert->is($counts{SlaY}, 1100,
            'fusion: un nick a cheval vif/archive compte sa somme');
        my $rank_slay = 1 + scalar grep { $counts{$_} > $counts{SlaY} } keys %counts;
        $assert->is($rank_slay, 1,
            'rank fusionne: SlaY (1100) passe devant aur (900) — l\'ancien HAVING par branche l\'aurait relegue');
    }

    # [2] la surface carriere complete passe par le gather
    my $src = _slurp_765(File::Spec->catfile('Mediabot', 'UserCommands.pm'))
              . "\n" . _slurp_765(File::Spec->catfile('Mediabot', 'SocialHistory.pm'));
    my @career = qw(
        mbStats_ctx mbTop_ctx mbStreak_ctx mbLeaderboard_ctx
        mbWordCount_ctx mbLast_ctx mbCompat_ctx
        mbSeen_ctx mbWhen_ctx mbCompare_ctx mbHeatmap_ctx
        mbProfil_ctx mbDashboard_ctx mbChronos_ctx mbMilestone_ctx
    );
    for my $sub_name (@career) {
        my $body = _sub_src_765($src, $sub_name);
        $assert->ok(defined $body, "$sub_name isolee");
        $assert->like($body, qr/channel_log_gather/,
            "$sub_name: vision vif+archive par requetes par table");
    }

    # [3] aucun UNION ALL dans du SQL reel (les commentaires ne comptent pas)
    my @union_sql = grep { $_ !~ /^\s*#/ && /UNION ALL/ } split /\n/, $src;
    $assert->is(join('|', @union_sql), '',
        'aucun UNION ALL hors commentaires dans UserCommands');
    my $helpers_src = _slurp_765(File::Spec->catfile('Mediabot', 'Helpers.pm'));
    my @union_help = grep { $_ !~ /^\s*#/ && /UNION ALL/ } split /\n/, $helpers_src;
    $assert->is(join('|', @union_help), '',
        'aucun UNION ALL hors commentaires dans Helpers');

    # [5] fenetres recentes en vif dur
    my $dash = _sub_src_765($src, 'mbDashboard_ctx');
    $assert->like($dash, qr/FROM CHANNEL_LOG cl\n.*INTERVAL 7 DAY/s,
        'dashboard: la sparkline 7 jours reste sur le vif');
    my $mile = _sub_src_765($src, 'mbMilestone_ctx');
    $assert->like($mile, qr/FROM CHANNEL_LOG\n.*INTERVAL 30 DAY/s,
        'milestone: le taux 30 jours reste sur le vif');
};
