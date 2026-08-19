# t/cases/766_mb577_gather_scope_and_failure_semantics.t
# =============================================================================
# mb577 — securisation du gather (revue pre-commit apres mb576) :
#   [1] SCOPE : l'archive n'est jointe que si elle peut CONTENIR les donnees —
#       scope content -> CONTENT_DAYS>0 ; presence -> PRESENCE_DAYS>0 ;
#       all -> l'une des deux. Conf Undernet (CONTENT=0, PRESENCE=7) : les
#       commandes de contenu ne touchent PAS l'archive.
#   [2] VIDE != PANNE : zero ligne est un succes SQL valide (live_ok=1) ;
#       « m last NickInconnu » ne repond plus « Database error ».
#   [3] PANNES : vif KO -> live_ok=0 (echec franc) ; archive KO -> live_ok=1,
#       resultat du vif conserve, echec logue.
#   [4] CASSE : les cles de fusion par nick sont normalisees lc — SlaY en
#       archive et slay en vif fusionnent en une identite.
#   [5] SEMANTIQUE : les metriques affichees en « msg » filtrent
#       event_type IN ('public','action') ; plus de DATE(cl.ts)= non
#       indexable ; wordcount all streame (pas d'accumulation globale).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_766 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

sub _sub_src_766 {
    my ($src, $name) = @_;
    my ($body) = $src =~ /(sub \Q$name\E \{.*?\n\})/s;
    return $body;
}

# Conf minimale pilotable
package Mb577::FakeConf;
sub new { my ($c,%kv)=@_; bless { %kv }, $c }
sub get { my ($self,$k)=@_; return $self->{$k} }

# Sth/Dbh avec panne injectable par table
package Mb577::FakeSth;
sub new { my ($c,$rows,$die_exec)=@_; bless { rows=>[@$rows], die_exec=>$die_exec }, $c }
sub execute { my ($self)=@_; die "boom-exec\n" if $self->{die_exec}; 1 }
sub fetchrow_hashref { my ($self)=@_; shift @{ $self->{rows} } }
sub finish { 1 }
sub errstr { 'fake' }

package Mb577::FakeDbh;
# by_tbl: { 'CHANNEL_LOG ' => { rows=>[...], die_prepare=>0, die_exec=>0 }, ... }
sub new { my ($c,%by_tbl)=@_; bless { by_tbl=>\%by_tbl, seen=>[] }, $c }
sub errstr { 'fake-dbh' }
sub prepare {
    my ($self,$sql)=@_;
    push @{ $self->{seen} }, $sql;
    for my $tbl (sort keys %{ $self->{by_tbl} }) {
        next unless index($sql, $tbl) >= 0;
        my $spec = $self->{by_tbl}{$tbl};
        die "boom-prepare\n" if $spec->{die_prepare};
        return Mb577::FakeSth->new($spec->{rows} || [], $spec->{die_exec});
    }
    return Mb577::FakeSth->new([], 0);
}

package main;

return sub {
    my ($assert) = @_;

    require Mediabot::Helpers;

    my $ARCH = 'mediabot2.CHANNEL_LOG_ARCHIVE';
    my $mkbot = sub {
        my (%days) = @_;
        return {
            conf => Mb577::FakeConf->new(
                'mysql.CHANNEL_LOG_ARCHIVE_PRESENCE_DAYS' => $days{presence},
                'mysql.CHANNEL_LOG_ARCHIVE_CONTENT_DAYS'  => $days{content},
            ),
        };
    };

    no warnings 'redefine';
    local *Mediabot::Helpers::channel_log_archive_table = sub { $ARCH };

    # [1] matrice de scope — conf Undernet: presence=7, content=0
    my $undernet = $mkbot->(presence => 7, content => 0);
    $assert->is(join(',', Mediabot::Helpers::channel_log_sources($undernet, 'content')),
        'CHANNEL_LOG',
        'scope content + CONTENT_DAYS=0 (conf Undernet): vif seul');
    $assert->is(join(',', Mediabot::Helpers::channel_log_sources($undernet, 'presence')),
        "CHANNEL_LOG,$ARCH",
        'scope presence + PRESENCE_DAYS=7: vif + archive');
    $assert->is(join(',', Mediabot::Helpers::channel_log_sources($undernet, 'all')),
        "CHANNEL_LOG,$ARCH",
        'scope all: archive jointe des qu une politique est active');

    my $content_on = $mkbot->(presence => 7, content => 730);
    $assert->is(join(',', Mediabot::Helpers::channel_log_sources($content_on, 'content')),
        "CHANNEL_LOG,$ARCH",
        'scope content + CONTENT_DAYS=730: vif + archive');

    my $nothing = $mkbot->(presence => 0, content => 0);
    for my $sc (qw(content presence all)) {
        $assert->is(join(',', Mediabot::Helpers::channel_log_sources($nothing, $sc)),
            'CHANNEL_LOG', "aucune politique active: vif seul (scope $sc)");
    }

    # [2] vide != panne : zero ligne -> live_ok=1, rows=0
    {
        my $dbh = Mb577::FakeDbh->new(
            'CHANNEL_LOG ' => { rows => [] },
            "$ARCH "       => { rows => [] },
        );
        my $g = Mediabot::Helpers::channel_log_gather($undernet, $dbh,
            'SELECT x FROM __CLSRC__ cl WHERE nick = ?', [ 'NickInconnu' ],
            sub {}, 'presence');
        $assert->is($g->{live_ok}, 1, 'zero ligne: succes SQL valide (live_ok=1)');
        $assert->is($g->{rows}, 0, 'zero ligne: rows=0');
        $assert->is($g->{ok_sources}, 2, 'zero ligne: les deux sources ont reussi');
    }

    # [3] pannes : vif KO -> live_ok=0 ; archive KO -> live_ok=1 + vif conserve
    {
        my $dbh = Mb577::FakeDbh->new(
            'CHANNEL_LOG ' => { die_prepare => 1 },
            "$ARCH "       => { rows => [ { n => 1 } ] },
        );
        my $g = Mediabot::Helpers::channel_log_gather($undernet, $dbh,
            'SELECT n FROM __CLSRC__ cl', [], sub {}, 'presence');
        $assert->is($g->{live_ok}, 0, 'vif en panne: echec franc (live_ok=0)');
    }
    {
        my @got;
        my $dbh = Mb577::FakeDbh->new(
            'CHANNEL_LOG ' => { rows => [ { nick => 'slay', cnt => 800 } ] },
            "$ARCH "       => { die_exec => 1 },
        );
        my $g = Mediabot::Helpers::channel_log_gather($undernet, $dbh,
            'SELECT nick, cnt FROM __CLSRC__ cl', [],
            sub { push @got, $_[0] }, 'presence');
        $assert->is($g->{live_ok}, 1, 'archive en panne: le vif fait foi');
        $assert->is(scalar @got, 1, 'archive en panne: resultat du vif conserve');
        $assert->is($g->{ok_sources}, 1, 'archive en panne: une seule source ok');
    }

    # [4] casse : SlaY (archive) + slay (vif) fusionnent via lc
    {
        my $dbh = Mb577::FakeDbh->new(
            'CHANNEL_LOG ' => { rows => [ { nick => 'slay', cnt => 800 } ] },
            "$ARCH "       => { rows => [ { nick => 'SlaY', cnt => 300 } ] },
        );
        my (%counts, %display);
        Mediabot::Helpers::channel_log_gather($undernet, $dbh,
            'SELECT nick, cnt FROM __CLSRC__ cl', [],
            sub {
                my $k = lc $_[0]->{nick};
                $display{$k} //= $_[0]->{nick};
                $counts{$k} += $_[0]->{cnt};
            }, 'presence');
        $assert->is(scalar keys %counts, 1, 'casse: une seule identite fusionnee');
        $assert->is($counts{slay}, 1100, 'casse: slay 800 + SlaY 300 = 1100');
    }

    # [5] semantique dans UserCommands
    my $src = _slurp_766(File::Spec->catfile('Mediabot', 'UserCommands.pm'))
            . "\n" . _slurp_766(File::Spec->catfile('Mediabot', 'SocialHistory.pm'));

    # 5a. event_type explicite sur les metriques « msg »
    # mb578: mbWhen_ctx retiree de cette liste — « when » = premiere
    # APPARITION (tout event_type, scope all) + compteur de messages
    # (public/action, scope content) ; l'obligation globale verrouillait
    # la mauvaise semantique. Sa verification ciblee vit dans 767.
    for my $sub_name (qw(mbStats_ctx mbTop_ctx mbStreak_ctx mbCompare_ctx
                         mbHeatmap_ctx)) {
        my $body = _sub_src_766($src, $sub_name);
        $assert->ok(defined $body, "$sub_name isolee");
        $assert->like($body, qr/event_type IN \('public','action'\)/,
            "$sub_name: filtre public/action explicite");
    }

    # 5b. plus de DATE(cl.ts) = non indexable
    my @bad_date = grep { $_ !~ /^\s*#/ && /DATE\(cl\.ts\) = / } split /\n/, $src;
    $assert->is(join('|', @bad_date), '',
        'aucun predicat DATE(cl.ts)= (plages indexables partout)');

    # 5c. wordcount all streame (callback ternaire sur $no_limit)
    my $wc = _sub_src_766($src, 'mbWordCount_ctx');
    $assert->like($wc,
        qr/\$no_limit\n?\s*\? sub \{ \$wc_count_text->/,
        'wordcount: mode all streame dans les compteurs');

    # 5d. les succes se lisent sur live_ok (vide n est plus une erreur)
    for my $pat (qw(stats_g top_g streak_g last_g when_first_g when_msgs_g
                    stats_first_g cmp_g hm_g wc_g ms_g)) {
        $assert->like($src, qr/\$\Q$pat\E->\{live_ok\}/,
            "succes via live_ok: \$$pat");
    }

    # 5e. chaque appel gather UserCommands/SocialHistory porte un scope explicite
    my $n_calls  = () = $src =~ /Mediabot::Helpers::channel_log_gather\(/g;
    # mb667/full-suite: whitespace between the explicit scope and the final
    # call parenthesis is formatting, not semantics (mb664 memory uses it).
    my $n_scoped = () = $src =~ /,\s*'(?:content|presence|all)'\s*\);/g;
    $assert->ok($n_calls > 0, 'des appels gather existent');
    $assert->is($n_scoped, $n_calls,
        'tous les gather UserCommands/SocialHistory sont scopes');
};
