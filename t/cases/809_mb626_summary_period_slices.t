# t/cases/809_mb626_summary_period_slices.t
# =============================================================================
# mb626 — une periode est lue SUR TOUTE SA LARGEUR, et le total annonce est
# le vrai.
#
# DEFAUT (le meme que celui signale par teuk en mb623, a une autre echelle) :
# la lecture d'une periode restait « ORDER BY id DESC LIMIT 1500 ». Sur une
# journee a 4000 messages, « ai summary today » lisait donc les 1500 DERNIERS,
# puis echantillonnait « de maniere repartie »... sur cette fin seulement. Le
# bot annoncait « 1500+ » : il avouait un plafond, mais revendiquait une
# couverture qu'il n'avait pas.
#
#   [1] bornes de periode : chaque periode rend un debut et une fin.
#   [2] decoupage : les bornes intermediaires sont calculees par la base,
#       monotones, et les extremites sont exactes.
#   [3] sous le plafond : UNE seule requete de lecture — comportement
#       historique inchange.
#   [4] au-dessus : une requete de comptage puis UNE LECTURE PAR TRANCHE,
#       chacune bornee dans le temps — la couverture est reelle.
#   [5] le total annonce est le COMPTE EXACT, plus « 1500+ ».
#   [6] le filtre pseudo s'applique aussi au comptage (sinon on annoncerait
#       le total du canal pour le resume d'une personne).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

return sub {
    my ($assert) = @_;

    require Mediabot::External::Claude;
    my $C = 'Mediabot::External::Claude';

    # [1] bornes
    my $B = $C->can('_summary_period_bounds');
    $assert->ok($B, 'mb626-809: les bornes de periode sont exposees');
    my %expect = (
        today     => [ 'CURDATE()', 'CURDATE() + INTERVAL 1 DAY' ],
        yesterday => [ 'CURDATE() - INTERVAL 1 DAY', 'CURDATE()' ],
    );
    my $ok = 0;
    for my $p (sort keys %expect) {
        my ($a, $b) = $B->($p);
        $ok++ if defined $a && $a eq $expect{$p}[0] && $b eq $expect{$p}[1];
    }
    $assert->is($ok, 2, 'mb626-809: today et yesterday sont des PLAGES fermees');
    my ($ds, $de) = $B->('days', 7);
    $assert->like($ds, qr/INTERVAL 7 DAY/, 'mb626-809: <N>d porte son nombre');
    my ($hs) = $B->('hours', 6);
    $assert->like($hs, qr/INTERVAL 6 HOUR/, 'mb626-809: <N>h aussi');
    my ($ls) = $B->('last', undef, 1700000000);
    $assert->like($ls, qr/FROM_UNIXTIME\(1700000000\)/,
        'mb626-809: last part du dernier resume');
    my ($fallback) = $B->('last', undef, 0);
    $assert->is($fallback, 'CURDATE()',
        'mb626-809: sans resume precedent, last retombe sur la journee');
    $assert->ok(!defined(($B->(undef))[0]),
        'mb626-809: sans periode, aucune borne (mode N derniers messages)');

    # [2] decoupage
    my $S = $C->can('_summary_slice_bound');
    $assert->is($S->('A', 'B', 0, 8), 'A', 'mb626-809: la tranche 0 commence au debut');
    $assert->is($S->('A', 'B', 8, 8), 'B', 'mb626-809: la derniere finit a la fin');
    my $mid = $S->('A', 'B', 4, 8);
    $assert->like($mid, qr/TIMESTAMPDIFF\(SECOND, A, B\) \* 4 \/ 8/,
        'mb626-809: les bornes intermediaires sont calculees par la base');
    $assert->like($mid, qr/TIMESTAMPADD\(SECOND/,
        'mb626-809: ... et rendues comme un instant, pas un nombre');

    # [3]-[6] comportement reel sur une base simulee
    {
        package DbhSlice;
        sub new { my ($c,%a)=@_; bless { rows => $a{rows}, total => $a{total},
                                         fail_count => ($a{fail_count} // 0),
                                         log => [], nick_binds => [] }, $c }
        sub prepare {
            my ($self, $sql) = @_;
            push @{ $self->{log} }, $sql;
            return StSlice->new($self, $sql);
        }
    }
    {
        package StSlice;
        sub new { my ($c,$dbh,$sql)=@_; bless { dbh=>$dbh, sql=>$sql, fed=>0 }, $c }
        sub execute {
            my ($self, @bind) = @_;
            $self->{count} = ($self->{sql} =~ /COUNT\(\*\)/) ? 1 : 0;
            $self->{limit} = $bind[-1] unless $self->{count};
            push @{ $self->{dbh}{nick_binds} }, scalar(@bind);
            return 0 if $self->{count} && $self->{dbh}{fail_count};
            return 1;
        }
        sub fetchrow_array { my $s=shift; return $s->{dbh}{total} }
        sub fetchrow_hashref {
            my ($self) = @_;
            return undef if $self->{count};
            my $max = $self->{limit} // 1;
            return undef if $self->{fed} >= $max || $self->{fed} >= $self->{dbh}{rows};
            $self->{fed}++;
            return { nick => 'x', text => "l$self->{fed}" };
        }
        sub finish { 1 }
    }

    my $count_sql = sub { scalar grep { /COUNT\(\*\)/ } @{ $_[0]{log} } };
    my $read_sql  = sub { scalar grep { !/COUNT\(\*\)/ && /SELECT cl.nick/ } @{ $_[0]{log} } };

    # petite periode : une seule lecture
    my $small = DbhSlice->new(rows => 300, total => 300);
    _run_summary($small, 'today');
    $assert->is($count_sql->($small), 1, 'mb626-809: la periode est comptee');
    $assert->is($read_sql->($small), 1,
        'mb626-809: sous le plafond, UNE lecture — comportement historique');

    # grosse periode : comptage + une lecture PAR TRANCHE
    my $big = DbhSlice->new(rows => 400, total => 4213);
    my $out = _run_summary($big, 'today');
    $assert->is($count_sql->($big), 1, 'mb626-809: comptage unique');
    $assert->is($read_sql->($big), $Mediabot::External::Claude::CLAUDE_SUMMARY_SLICES,
        'mb626-809: une lecture par tranche — la fenetre entiere est couverte');
    my @bounded = grep { /cl\.ts >= .*AND cl\.ts < / } @{ $big->{log} };
    $assert->is(scalar @bounded, 1 + $Mediabot::External::Claude::CLAUDE_SUMMARY_SLICES,
        'mb626-809: chaque lecture est bornee dans le temps, comptage inclus');
    $assert->ok((grep { /TIMESTAMPADD\(SECOND/ } @{ $big->{log} }),
        'mb626-809: les tranches utilisent bien les bornes calculees');

    # [5] total exact annonce
    $assert->like($out, qr/\b4213\b/,
        'mb626-809: le total EXACT de la periode est annonce');
    $assert->ok($out !~ /1500\+/,
        'mb626-809: plus de « 1500+ » — le plafond ne sert plus de reponse');

    # [6] le filtre pseudo s'applique au comptage
    my $withnick = DbhSlice->new(rows => 50, total => 50);
    _run_summary($withnick, 'today teuk');
    my ($cq) = grep { /COUNT\(\*\)/ } @{ $withnick->{log} };
    $assert->like($cq, qr/LOWER\(cl\.nick\) = \?/,
        'mb626-809: le comptage porte le meme filtre pseudo que la lecture');


    # mb628: le contrat « total exact » echoue ferme. Si le COUNT ne peut pas
    # etre etabli, on ne retombe surtout pas sur les 1500 derniers messages.
    my $countfail = DbhSlice->new(rows => 1500, total => 9999, fail_count => 1);
    my $failout = _run_summary($countfail, 'today');
    $assert->like($failout, qr/DB error\./,
        'mb628-809: echec du comptage => erreur DB explicite');
    $assert->is($read_sql->($countfail), 0,
        'mb628-809: echec du comptage => aucune lecture tronquee de repli');

    # Le mode last etait historiquement strict (ts > dernier resume), pas >=.
    my $lastdbh = DbhSlice->new(rows => 20, total => 20);
    _run_summary($lastdbh, 'last', 1700000000);
    my ($last_count) = grep { /COUNT\(\*\)/ } @{ $lastdbh->{log} };
    $assert->like($last_count, qr/cl\.ts > FROM_UNIXTIME\(1700000000\)/,
        'mb628-809: last conserve sa borne de depart strictement exclusive');
};

# Joue la sous-commande summary contre une base simulee, rend la sortie.
sub _run_summary {
    my ($dbh, $argline, $last_ts) = @_;
    my @out;
    no warnings 'redefine';
    local *Mediabot::Helpers::botNotice  = sub { push @out, $_[2]; 1 };
    local *Mediabot::Helpers::botPrivmsg = sub { push @out, $_[2]; 1 };
    local *Mediabot::Helpers::isIrcChannelTarget = sub { 1 };
    local *Mediabot::Helpers::channel_lang = sub { 'en' };
    local *Mediabot::External::Claude::claudeAI = sub { 1 };

    my $bot = bless {
        dbh => $dbh,
        channels => { '#c' => 1 },
        _claude_summary_ts => (defined $last_ts ? { 'summary_last:#c' => $last_ts } : {}),
    }, 'Mediabot';
    my $ctx = CtxSlice->new(bot => $bot, args => [ 'summary', split(/ /, $argline) ]);
    eval { Mediabot::External::Claude::claude_ctx($ctx) };
    die $@ if $@ && $ENV{MB_DEBUG_809};
    return join "\n", @out;
}

{
    package CtxSlice;
    sub new { my ($c,%a)=@_; bless { %a }, $c }
    sub bot { $_[0]{bot} } sub nick { 'teuk' } sub channel { '#c' }
    sub args { $_[0]{args} } sub message { {} }
}
