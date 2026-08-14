# t/cases/817_mb636_ai_summary_channel_target.t
# =============================================================================
# mb636 — « ai [#canal] summary » : résumer un AUTRE canal depuis une console.
#
# DEMANDE teuk : depuis #teuk (canal console), pouvoir faire
#   m ai #35+ans summary          -> notice, Administrator+
#   m ai #35+ans summary public   -> sur le canal COURANT, Master+
# les formes historiques restant inchangées :
#   m ai summary | ai summary public | ai summary today | ai summary 7d
#
#   [1] deux canaux DISTINCTS et tenus séparés : celui qu'on LIT (source) et
#       celui où l'on PARLE (destination de « public »).
#   [2] sans cible, source = canal courant : comportement historique intact.
#   [3] le jeton #canal n'est reconnu QUE devant 'summary' — sinon
#       « ai #linux c'est quoi ? » perdrait son premier mot.
#   [4] NIVEAUX : Administrator pour résumer ; Master EN PLUS pour publier le
#       résumé d'un AUTRE canal sur le canal courant. Un refus ne lit rien.
#   [5] canal inconnu du bot : dit, plutôt que « aucun message » trompeur.
#   [6] tout ce qui LIT vise la source (requêtes, horodatage 'last', langue,
#       annonce) ; seule la sortie vise le canal courant.
# =============================================================================

use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

{ package ConfT; sub new { bless {}, shift } sub get { undef } }
{ package LogT;  sub new { bless {}, shift } sub log { 1 } }
{ package ChanT; sub new { my ($c,$n)=@_; bless { name=>$n }, $c } sub get_name { $_[0]{name} } }
{
    package CtxT;
    sub new { my ($c,%a)=@_; bless { %a, asked => [] }, $c }
    sub bot { $_[0]{bot} } sub nick { 'teuk' }
    sub channel { $_[0]{channel} } sub args { $_[0]{args} } sub message { {} }
    sub require_level {
        my ($s, $lvl) = @_;
        push @{ $s->{asked} }, $lvl;
        return $s->{level_ok}{$lvl} ? 1 : 0;
    }
}
{
    package DbhT;
    sub new { bless { sql => [], binds => [] }, shift }
    sub prepare { my ($s,$q)=@_; push @{ $s->{sql} }, $q; return StT->new($s,$q) }
}
{
    package StT;
    sub new { my ($c,$d,$q)=@_; bless { d=>$d, q=>$q, n=>0 }, $c }
    sub execute { my ($s,@b)=@_; push @{ $s->{d}{binds} }, $b[0]; 1 }
    sub fetchrow_array { 12 }
    sub fetchrow_hashref {
        my $s = shift;
        return undef if $s->{q} =~ /COUNT/;
        return undef if $s->{n}++ >= 3;
        return { nick => "u$s->{n}", text => "ligne $s->{n}" };
    }
    sub finish { 1 }
}

# Joue la commande et rend (sorties, niveaux demandés, canal réellement lu).
sub _run {
    my (%p) = @_;
    my @out;
    no warnings 'redefine';
    local *Mediabot::Helpers::botPrivmsg = sub { push @out, [ $_[1], $_[2] ]; 1 };
    local *Mediabot::Helpers::botNotice  = sub { push @out, [ 'notice', $_[2] ]; 1 };
    local *Mediabot::Helpers::channel_lang = sub { 'fr' };
    local *Mediabot::External::Claude::claudeAI = sub { 1 };

    my $dbh = DbhT->new;
    my $bot = bless { conf => ConfT->new, logger => LogT->new, dbh => $dbh,
                      channels => {
                          '#teuk'   => ChanT->new('#teuk'),
                          '#35+ans' => ChanT->new('#35+ans'),
                      } }, 'Mediabot';
    my $ctx = CtxT->new(bot => $bot, channel => $p{channel}, args => $p{args},
                        level_ok => $p{levels});
    Mediabot::External::Claude::claude_ctx($ctx);
    my ($read) = grep { defined } @{ $dbh->{binds} };
    return (\@out, $ctx->{asked}, $read, $dbh);
}

my %ADMIN  = ('Administrator' => 1);
my %MASTER = ('Administrator' => 1, 'Master' => 1);

return sub {
    my ($assert) = @_;
    require Mediabot::External::Claude;
    require Mediabot::Helpers;

    # [2] formes historiques : source = canal courant, sortie en notice
    my ($out, $asked, $read) = _run(channel => '#teuk', args => ['summary'], levels => \%ADMIN);
    $assert->is($read, '#teuk', 'mb636-817: sans cible, on lit le canal courant');
    $assert->is($out->[0][0], 'notice', 'mb636-817: reponse en notice par defaut');
    $assert->is(join(',', @$asked), 'Administrator',
        'mb636-817: Administrator suffit pour le canal courant');

    ($out, $asked, $read) = _run(channel => '#teuk', args => ['summary','public'], levels => \%ADMIN);
    $assert->is($out->[0][0], '#teuk', 'mb636-817: « public » repond sur le canal');
    $assert->is(join(',', @$asked), 'Administrator',
        'mb636-817: publier SON PROPRE canal ne demande pas Master');

    ($out, $asked, $read) = _run(channel => '#teuk', args => ['summary','today'], levels => \%ADMIN);
    $assert->like($out->[0][1], qr/aujourd/, 'mb636-817: la periode today reste lue');
    $assert->is($out->[0][0], 'notice', 'mb636-817: ... en notice');
    ($out, undef, $read) = _run(channel => '#teuk', args => ['summary','7d'], levels => \%ADMIN);
    $assert->like($out->[0][1], qr/7 derniers jours/, 'mb636-817: la periode 7d aussi');

    # [1] cible explicite : on lit ailleurs, on repond en notice
    ($out, $asked, $read) = _run(channel => '#teuk', args => ['#35+ans','summary'], levels => \%ADMIN);
    $assert->is($read, '#35+ans', 'mb636-817: le canal NOMME est celui qu on lit');
    $assert->is($out->[0][0], 'notice', 'mb636-817: ... reponse en notice');
    $assert->like($out->[0][1], qr/#35\+ans/,
        'mb636-817: ... et l annonce nomme le canal resume');
    $assert->is(join(',', @$asked), 'Administrator',
        'mb636-817: lire un autre canal pour soi = Administrator');

    # mb637: la graphie fournie n'est pas l'identite du canal. Une variante de
    # casse doit retomber sur le nom canonique de l'objet Channel, sinon SQL et
    # surtout summary_last peuvent se separer en plusieurs timelines.
    ($out, $asked, $read) = _run(channel => '#teuk', args => ['#35+ANS','summary'], levels => \%ADMIN);
    $assert->is($read, '#35+ans',
        'mb637-817: une cible avec une autre casse est lue sous son nom canonique');
    $assert->like($out->[0][1], qr/#35\+ans/,
        'mb637-817: l annonce utilise aussi le nom canonique');

    # [4] croisement PUBLIC : Master exige, et un refus ne lit RIEN
    my $dbh;
    ($out, $asked, $read, $dbh) =
        _run(channel => '#teuk', args => ['#35+ans','summary','public'], levels => \%ADMIN);
    $assert->is(join(',', @$asked), 'Administrator,Master',
        'mb636-817: publier un AUTRE canal ici demande Master');
    $assert->is(scalar @$out, 0, 'mb636-817: refuse -> aucune sortie');
    $assert->is(scalar @{ $dbh->{sql} }, 0,
        'mb636-817: refuse -> AUCUNE requete (rien n est lu avant la porte)');

    ($out, $asked, $read) =
        _run(channel => '#teuk', args => ['#35+ans','summary','public'], levels => \%MASTER);
    $assert->is($read, '#35+ans', 'mb636-817: Master -> le canal nomme est lu');
    $assert->is($out->[0][0], '#teuk',
        'mb636-817: ... et la reponse sort sur le canal COURANT');
    $assert->like($out->[0][1], qr/#35\+ans/,
        'mb636-817: ... en nommant le canal resume');

    # [5] canal inconnu
    ($out, $asked, $read, $dbh) =
        _run(channel => '#teuk', args => ['#nulle-part','summary'], levels => \%ADMIN);
    $assert->like($out->[0][1], qr/don't know the channel #nulle-part/,
        'mb636-817: un canal inconnu est annonce comme tel');
    $assert->is(scalar @{ $dbh->{sql} }, 0,
        'mb636-817: ... sans interroger la base');

    # [3] le jeton canal ne vole pas un prompt
    my $src = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/External/Claude.pm'
        or die $!; local $/; <$fh> };
    $assert->like($src,
        qr/if \(\@args >= 2 && \$args\[0\] =~ \/\\A\[#&\]\\S\+\\z\/ && lc\(\$args\[1\]\) eq 'summary'\)/,
        'mb636-817: le #canal n est pris QUE devant summary');

    # [6] separation source / destination dans tout le corps
    my ($branch) = $src =~ /(if \(\@args && lc\(\$args\[0\]\) eq 'summary'\) \{.*?\n    \})/s;
    $assert->ok(defined $branch, 'mb636-817: branche summary localisee');
    for my $must (
        [ qr/\$q->execute\(\$src_channel,/,                 'la lecture des messages' ],
        [ qr/\$cq->execute\(\$src_channel,/,                'le comptage' ],
        [ qr/summary_last:\$src_channel/,                   'l horodatage du dernier resume' ],
        [ qr/resolve_ai_lang\(\$self, \$src_channel,/,      'la langue' ],
    ) {
        $assert->like($branch, $must->[0], "mb636-817: $must->[1] vise la SOURCE");
    }
    $assert->like($branch, qr/botPrivmsg\(\$self, \$channel, \$_\[0\]\)/,
        'mb636-817: la sortie publique vise le canal COURANT');
    $assert->like($branch, qr/my \$cross = \(lc\(\$src_channel\) ne lc\(\$channel \/\/ ''\)\) \? 1 : 0;/,
        'mb636-817: le croisement est calcule explicitement');
    $assert->like($src, qr/my \$src_channel = _summary_canonical_channel\(\$self, \$requested_src_channel\)/,
        'mb637-817: la branche remplace la graphie demandee par l identite canonique');

    # la syntaxe documentee dit tout cela
    my @usage = Mediabot::External::Claude::_summary_usage();
    my $usage = join "\n", @usage;
    $assert->like($usage, qr/ai \[#canal\] summary/, 'mb636-817: syntaxe a jour');
    $assert->like($usage, qr/Master\+ pour publier le resume d'un\s+AUTRE canal/,
        'mb636-817: le niveau du croisement est documente');
    $assert->like($usage, qr/#35\+ans summary public/,
        'mb636-817: l exemple demande figure dans l aide');
};
