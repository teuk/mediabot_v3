# t/cases/767_mb578_when_stats_semantics_live_errors.t
# =============================================================================
# mb578 — semantique « premiere apparition » + contrat LIVE applique partout :
#   [1] when : DEUX gathers — premiere apparition (tout event_type, scope
#       'all' : un JOIN archive anterieur au premier message fait foi, un
#       nick apparu sans parler n'est plus declare absent) + compteur de
#       messages (public/action, scope 'content'). Fusion : le JOIN le plus
#       ancien gagne meme s'il vit dans l'archive de presence.
#   [2] stats : msg_count/last_msg restent des messages (content) ;
#       first_seen = premiere TRACE via gather separe scope 'all' sans
#       filtre event_type.
#   [3] helper : panne LIVE = arret IMMEDIAT (l'archive n'est ni preparee ni
#       executee) ; panne archive apres LIVE reussi = vif conserve ; erreur
#       de fetch detectee via $sth->err.
#   [4] contrat LIVE partout : dans chaque sub carriere, chaque gather est
#       capture et verifie par live_ok — aux deux exceptions DOCUMENTEES
#       pres (ligne bonus « your rank » du top, « activity rank » du
#       wordcount), qui degradent proprement au lieu d'inventer un rang.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_767 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

sub _sub_src_767 {
    my ($src, $name) = @_;
    my ($body) = $src =~ /(sub \Q$name\E \{.*?\n\})/s;
    return $body;
}

package Mb578::FakeConf;
sub new { my ($c,%kv)=@_; bless { %kv }, $c }
sub get { my ($self,$k)=@_; return $self->{$k} }

package Mb578::FakeSth;
sub new { my ($c,%s)=@_; bless { rows=>[@{ $s{rows}||[] }], die_exec=>$s{die_exec}, fetch_err=>$s{fetch_err} }, $c }
sub execute { my ($self)=@_; die "boom-exec\n" if $self->{die_exec}; 1 }
sub fetchrow_hashref { my ($self)=@_; shift @{ $self->{rows} } }
sub err { my ($self)=@_; return $self->{fetch_err} ? 7 : 0 }
sub finish { 1 }
sub errstr { 'fake' }

package Mb578::FakeDbh;
sub new { my ($c,%by_tbl)=@_; bless { by_tbl=>\%by_tbl, seen=>[] }, $c }
sub errstr { 'fake-dbh' }
sub prepare {
    my ($self,$sql)=@_;
    for my $tbl (sort keys %{ $self->{by_tbl} }) {
        next unless index($sql, $tbl) >= 0;
        my $spec = $self->{by_tbl}{$tbl};
        push @{ $self->{seen} }, $tbl;
        die "boom-prepare\n" if $spec->{die_prepare};
        return Mb578::FakeSth->new(%$spec);
    }
    push @{ $self->{seen} }, '?';
    return Mb578::FakeSth->new();
}

package main;

return sub {
    my ($assert) = @_;

    require Mediabot::Helpers;

    my $ARCH = 'mediabot2.CHANNEL_LOG_ARCHIVE';
    my $bot = {
        conf => Mb578::FakeConf->new(
            'mysql.CHANNEL_LOG_ARCHIVE_PRESENCE_DAYS' => 7,
            'mysql.CHANNEL_LOG_ARCHIVE_CONTENT_DAYS'  => 0,
        ),
    };
    no warnings 'redefine';
    local *Mediabot::Helpers::channel_log_archive_table = sub { $ARCH };

    # [3a] panne LIVE (prepare) = arret immediat : l'archive n'est jamais
    # touchee (une seule entree dans le journal du dbh, celle du vif)
    {
        my $dbh = Mb578::FakeDbh->new(
            'CHANNEL_LOG ' => { die_prepare => 1 },
            "$ARCH "       => { rows => [ { n => 1 } ] },
        );
        my $g = Mediabot::Helpers::channel_log_gather($bot, $dbh,
            'SELECT n FROM __CLSRC__ cl', [], sub {}, 'presence');
        $assert->is($g->{live_ok}, 0, 'LIVE prepare KO: live_ok=0');
        $assert->is(join(',', @{ $dbh->{seen} }), 'CHANNEL_LOG ',
            'LIVE prepare KO: arret immediat, archive jamais preparee');
        $assert->is($g->{executed}, 1, 'LIVE prepare KO: une seule source tentee');
    }
    # [3b] panne LIVE (execute) = arret immediat aussi
    {
        my $dbh = Mb578::FakeDbh->new(
            'CHANNEL_LOG ' => { die_exec => 1 },
            "$ARCH "       => { rows => [ { n => 1 } ] },
        );
        my $g = Mediabot::Helpers::channel_log_gather($bot, $dbh,
            'SELECT n FROM __CLSRC__ cl', [], sub {}, 'presence');
        $assert->is($g->{live_ok}, 0, 'LIVE execute KO: live_ok=0');
        $assert->is(join(',', @{ $dbh->{seen} }), 'CHANNEL_LOG ',
            'LIVE execute KO: archive jamais executee');
    }
    # [3c] erreur de FETCH sur le vif = panne (les fins normales restent ok)
    {
        my $dbh = Mb578::FakeDbh->new(
            'CHANNEL_LOG ' => { rows => [ { n => 1 } ], fetch_err => 1 },
            "$ARCH "       => { rows => [ { n => 2 } ] },
        );
        my $g = Mediabot::Helpers::channel_log_gather($bot, $dbh,
            'SELECT n FROM __CLSRC__ cl', [], sub {}, 'presence');
        $assert->is($g->{live_ok}, 0, 'LIVE fetch err: live_ok=0');
        $assert->is(join(',', @{ $dbh->{seen} }), 'CHANNEL_LOG ',
            'LIVE fetch err: arret immediat');
    }
    # [3d] archive KO apres LIVE reussi : vif conserve, live_ok=1
    {
        my @got;
        my $dbh = Mb578::FakeDbh->new(
            'CHANNEL_LOG ' => { rows => [ { ts => '2026-01-01 00:00:00' } ] },
            "$ARCH "       => { die_exec => 1 },
        );
        my $g = Mediabot::Helpers::channel_log_gather($bot, $dbh,
            'SELECT ts FROM __CLSRC__ cl', [], sub { push @got, $_[0] }, 'presence');
        $assert->is($g->{live_ok}, 1, 'archive KO: le vif fait foi');
        $assert->is(scalar @got, 1, 'archive KO: resultat du vif conserve');
    }
    # [3e] contrat mb577 conserve : vide = succes
    {
        my $dbh = Mb578::FakeDbh->new(
            'CHANNEL_LOG ' => { rows => [] },
            "$ARCH "       => { rows => [] },
        );
        my $g = Mediabot::Helpers::channel_log_gather($bot, $dbh,
            'SELECT n FROM __CLSRC__ cl', [], sub {}, 'presence');
        $assert->is($g->{live_ok}, 1, 'vide: toujours un succes valide');
        $assert->is($g->{rows}, 0, 'vide: rows=0');
    }

    # [1] fusion when : un JOIN d'archive (2018) anterieur au premier message
    # vif (2024) fait foi comme premiere apparition
    {
        my $bot_all = {
            conf => Mb578::FakeConf->new(
                'mysql.CHANNEL_LOG_ARCHIVE_PRESENCE_DAYS' => 7,
                'mysql.CHANNEL_LOG_ARCHIVE_CONTENT_DAYS'  => 0,
            ),
        };
        my $dbh = Mb578::FakeDbh->new(
            'CHANNEL_LOG ' => { rows => [ { first_seen => '2024-05-01 10:00:00' } ] },
            "$ARCH "       => { rows => [ { first_seen => '2018-04-12 09:00:00' } ] },
        );
        my $first;
        my $g = Mediabot::Helpers::channel_log_gather($bot_all, $dbh,
            'SELECT MIN(cl.ts) AS first_seen FROM __CLSRC__ cl', [],
            sub {
                $first = $_[0]->{first_seen}
                    if defined $_[0]->{first_seen}
                    && (!defined $first || $_[0]->{first_seen} lt $first);
            }, 'all');
        $assert->is($g->{executed}, 2,
            'when(all): l archive de presence est consultee malgre CONTENT_DAYS=0');
        $assert->is($first, '2018-04-12 09:00:00',
            'when: le JOIN archive anterieur au premier message fait foi');
    }

    my $src = _slurp_767(File::Spec->catfile('Mediabot', 'UserCommands.pm'));

    # [1b] structure de when : gather all SANS filtre + gather content AVEC
    my $when = _sub_src_767($src, 'mbWhen_ctx');
    $assert->ok(defined $when, 'mbWhen_ctx isolee');
    my ($when_first_sql) = $when =~ /\$when_first_g = Mediabot::Helpers::channel_log_gather\(.*?q\{(.*?)\}/s;
    my ($when_msgs_sql)  = $when =~ /\$when_msgs_g = Mediabot::Helpers::channel_log_gather\(.*?q\{(.*?)\}/s;
    $assert->ok(defined $when_first_sql && $when_first_sql !~ /event_type/,
        'when/apparition: aucun filtre event_type');
    $assert->like($when, qr/\}, 'all'\);\s*\n\s*unless \(\$when_first_g->\{live_ok\}\)/,
        'when/apparition: scope all + live_ok');
    $assert->ok(defined $when_msgs_sql
            && $when_msgs_sql =~ /event_type IN \('public','action'\)/,
        'when/messages: filtre public/action');
    $assert->like($when, qr/\}, 'content'\);\s*\n\s*unless \(\$when_msgs_g->\{live_ok\}\)/,
        'when/messages: scope content + live_ok');
    $assert->like($when, qr/", \$tot_msgs msg\(s\)"/,
        'when: le total (y compris 0) est toujours affiche');

    # [2] structure de stats : first_seen separe, scope all, sans filtre
    my $stats = _sub_src_767($src, 'mbStats_ctx');
    my ($sf_sql) = $stats =~ /\$stats_first_g = Mediabot::Helpers::channel_log_gather\(.*?q\{(.*?)\}/s;
    $assert->ok(defined $sf_sql && $sf_sql =~ /MIN\(cl\.ts\) AS first_seen/
            && $sf_sql !~ /event_type/,
        'stats/first_seen: premiere trace sans filtre event_type');
    my ($sc_sql) = $stats =~ /\$stats_g = Mediabot::Helpers::channel_log_gather\(.*?q\{(.*?)\}/s;
    $assert->ok(defined $sc_sql && $sc_sql =~ /event_type IN \('public','action'\)/
            && $sc_sql !~ /first_seen/,
        'stats/compteurs: messages seulement, sans first_seen');

    # [4] contrat LIVE partout : comptage gathers vs checks live_ok par sub,
    # avec les DEUX exemptions documentees.
    my %expect = (
        mbStats_ctx       => { calls => 4, checks => 4 },
        # top: 3 gathers seulement — le caller rank reutilise la fusion en
        # memoire depuis mb576 (zero requete).
        mbTop_ctx         => { calls => 3, checks => 2, exempt => qr/\$mine = 0 unless \$top_mine_g->\{live_ok\}/ },
        mbStreak_ctx      => { calls => 1, checks => 1 },
        mbLeaderboard_ctx => { calls => 1, checks => 1 },
        mbWordCount_ctx   => { calls => 2, checks => 1, exempt => qr/\$wc_rank_g->\{live_ok\} && %wc_rank_counts/ },
        mbLast_ctx        => { calls => 1, checks => 1 },
        mbCompat_ctx      => { calls => 2, checks => 2 },
        mbSeen_ctx        => { calls => 2, checks => 2 },
        mbWhen_ctx        => { calls => 2, checks => 2 },
        mbCompare_ctx     => { calls => 1, checks => 1 },
        mbHeatmap_ctx     => { calls => 1, checks => 1 },
        mbProfil_ctx      => { calls => 3, checks => 3 },
        mbDashboard_ctx   => { calls => 3, checks => 3 },
        mbChronos_ctx     => { calls => 4, checks => 4 },
        mbMilestone_ctx   => { calls => 1, checks => 1 },
    );
    for my $sub_name (sort keys %expect) {
        my $body = _sub_src_767($src, $sub_name);
        $assert->ok(defined $body, "$sub_name isolee");
        my $calls  = () = $body =~ /Mediabot::Helpers::channel_log_gather\(/g;
        my $checks = () = $body =~ /unless \(\$\w+->\{live_ok\}\)/g;
        $assert->is($calls, $expect{$sub_name}{calls},
            "$sub_name: nombre de gathers attendu");
        $assert->is($checks, $expect{$sub_name}{checks},
            "$sub_name: chaque gather indispensable verifie live_ok");
        if (my $ex = $expect{$sub_name}{exempt}) {
            $assert->like($body, $ex,
                "$sub_name: l exemption documentee degrade proprement");
        }
    }
};
