# t/cases/758_mb568_flood_defer_and_index_hygiene.t
# =============================================================================
# mb568 — deux volets :
#
# A. L'anti-flood DIFFERE au lieu de jeter (le « m lb n'affiche pas tout ») :
#   [1] un message bloque par checkAntiFlood part en file bornee (30/canal)
#       et n'atteint pas le wire ; le timer de drain est arme quand une
#       boucle existe ;
#   [2] le drain renvoie UN message par tick via le chemin complet, dans
#       l'ordre d'origine ; re-blocage pendant le drain -> le message
#       reprend la TETE de file (ordre preserve) ;
#   [3] file pleine -> abandon trace niveau 3 (jamais silencieux) ;
#   [4] gardes statiques : plus AUCUN « return undef » sec sur
#       checkAntiFlood dans botPrivmsg NI botAction — les deux passent par
#       _defer_flooded_send.
#
# B. Hygiene d'index dans l'outil analyze :
#   [5] detection des index redondants (prefixe strict, doublon exact
#       dedoublonne), DROP suggere en online DDL, jamais execute.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::Helpers;

sub _slurp_758 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{
    package L758;
    sub new { bless { lines => [] }, shift }
    sub log { my ($self, $lvl, $msg) = @_; push @{ $self->{lines} }, [ $lvl, $msg ]; 1 }
    sub grep_level { my ($self, $lvl, $re) = @_; grep { $_->[0] == $lvl && $_->[1] =~ $re } @{ $self->{lines} } }
}

{
    # Faux loop : add() note le timer, start() note l'armement.
    package Loop758;
    sub new { bless { added => [] }, shift }
    sub add { push @{ $_[0]{added} }, $_[1]; 1 }
}

return sub {
    my ($assert) = @_;

    # ------------------------------------------------------------------
    # [1] Bloque -> file, pas de wire, timer arme
    # ------------------------------------------------------------------
    {
        my $loop = Loop758->new;
        my $bot = bless {
            logger => L758->new,
            loop   => $loop,
        }, 'Mediabot::Mediabot';

        my $r = Mediabot::Helpers::_defer_flooded_send($bot, 'privmsg', '#lab', 'ligne 1');
        $assert->ok($r, 'message bloque -> empile (retour vrai)');
        $assert->ok(scalar(@{ $bot->{_flood_outq}{'#lab'}{items} }) == 1, 'un item en file');
        $assert->ok($bot->{_flood_outq}{'#lab'}{armed} == 1, 'drain arme');
        $assert->ok(scalar(@{ $loop->{added} }) == 1, 'timer ajoute a la boucle');

        Mediabot::Helpers::_defer_flooded_send($bot, 'privmsg', '#lab', 'ligne 2');
        $assert->ok(scalar(@{ $bot->{_flood_outq}{'#lab'}{items} }) == 2
            && scalar(@{ $loop->{added} }) == 1,
            'deuxieme item empile sans rearmer un second timer');
    }

    # ------------------------------------------------------------------
    # [2] Drain : ordre preserve, re-blocage -> tete de file
    # ------------------------------------------------------------------
    {
        my $bot = bless { logger => L758->new, loop => Loop758->new }, 'Mediabot::Mediabot';
        my @wire;
        no warnings 'redefine';
        # On droppe le vrai botPrivmsg : selon le flag, il "envoie" ou re-bloque.
        my $blocked = 0;
        local *Mediabot::Helpers::botPrivmsg = sub {
            my ($self, $to, $msg) = @_;
            if ($blocked) {
                return Mediabot::Helpers::_defer_flooded_send($self, 'privmsg', $to, $msg);
            }
            push @wire, $msg;
            return 1;
        };

        Mediabot::Helpers::_defer_flooded_send($bot, 'privmsg', '#lab', 'A');
        Mediabot::Helpers::_defer_flooded_send($bot, 'privmsg', '#lab', 'B');
        Mediabot::Helpers::_defer_flooded_send($bot, 'privmsg', '#lab', 'C');

        Mediabot::Helpers::_drain_flood_queue($bot, '#lab');
        $assert->is(join(',', @wire), 'A', 'drain: UN message par tick, le premier');
        $assert->ok($bot->{_flood_outq}{'#lab'}{armed} == 1, 'drain: rearme (file non vide)');

        $blocked = 1;
        Mediabot::Helpers::_drain_flood_queue($bot, '#lab');
        $assert->is(join(',', @wire), 'A', 're-blocage: rien sur le wire');
        $assert->is($bot->{_flood_outq}{'#lab'}{items}[0][1], 'B',
            're-blocage: B reprend la TETE (ordre preserve)');

        $blocked = 0;
        Mediabot::Helpers::_drain_flood_queue($bot, '#lab');
        Mediabot::Helpers::_drain_flood_queue($bot, '#lab');
        $assert->is(join(',', @wire), 'A,B,C', 'ordre final intact');
        $assert->ok(scalar(@{ $bot->{_flood_outq}{'#lab'}{items} }) == 0, 'file videe');
    }

    # ------------------------------------------------------------------
    # [3] Borne
    # ------------------------------------------------------------------
    {
        my $logger = L758->new;
        my $bot = bless { logger => $logger, loop => Loop758->new }, 'Mediabot::Mediabot';
        Mediabot::Helpers::_defer_flooded_send($bot, 'privmsg', '#full', "m$_") for (1 .. 35);
        $assert->ok(scalar(@{ $bot->{_flood_outq}{'#full'}{items} }) == 30, 'file bornee a 30');
        $assert->ok(scalar($logger->grep_level(3, qr/flood queue full on #full/)) == 5,
            'abandons traces niveau 3');
    }

    # ------------------------------------------------------------------
    # [4] Gardes statiques Helpers
    # ------------------------------------------------------------------
    {
        my $src = _slurp_758(File::Spec->catfile('Mediabot', 'Helpers.pm'));
        $assert->unlike($src, qr/return undef if checkAntiFlood/,
            'botPrivmsg: plus de drop sec');
        my ($ba) = $src =~ /(sub botAction \{.*?\n\})/s;
        $assert->ok(defined $ba && $ba !~ /checkAntiFlood\(\$self,\$sTo\)\) \{\n\t*return undef;/,
            'botAction: plus de drop sec');
        my $defer_calls = () = $src =~ /_defer_flooded_send\(\$self,/g;
        $assert->ok($defer_calls >= 2, 'les deux emetteurs passent par la file');
    }

    # ------------------------------------------------------------------
    # [5] Detecteur de redondance dans l'outil
    # ------------------------------------------------------------------
    {
        my $tool = _slurp_758(File::Spec->catfile('tools', 'analyze_channel_log.pl'));
        $assert->like($tool, qr/Index redondants \(prefixe d\\'un autre index/,
            'tool: section redondance');
        $assert->like($tool, qr/DROP INDEX `%s`, ALGORITHM=INPLACE, LOCK=NONE;/,
            'tool: DROP suggere en online DDL');
        # mb569-B1: variables renommees name_a/name_b (le shadowing de $a/$b
        # cassait le sort interieur — incident du 2026-07-25).
        $assert->like($tool, qr/next if \@ca == \@cb && \$name_a lt \$name_b;/,
            'tool: doublon exact dedoublonne (une seule suggestion)');
        $assert->unlike($tool, qr/do\(\s*["']ALTER/i, 'tool: jamais execute');
    }
};
