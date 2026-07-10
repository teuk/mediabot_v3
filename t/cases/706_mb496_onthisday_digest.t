# t/cases/706_mb496_onthisday_digest.t
# =============================================================================
# mb496 — Digest quotidien "on this day" : une fois par jour, le bot poste
# spontanément le récap onthisday sur les canaux qui l'ont activé
# (chanset OnThisDayDigest, OPT-IN). Prolonge le !onthisday réactif (mb489) en
# rituel de canal.
#
#   [1] post_onthisday_digest : opt-in respecté, silence si pas d'historique,
#       post correct (en-tête + lignes) sinon, multi-canaux ;
#   [2] refactor : commande et digest partagent _onthisday_lines (une seule
#       implémentation SQL) ;
#   [3] intégration : chanset id 21, migration déclarée, tick calendar câblé,
#       heure configurable, garde publictext.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

require Mediabot::Mediabot;
use Mediabot::UserCommands;

sub _slurp_706 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{
    package L706; sub new { bless {}, shift } sub log { }
    package Chan706;
    sub new { my ($c,%a)=@_; bless { %a }, $c }
    sub get_name { $_[0]->{name} }
    sub get_id   { $_[0]->{id} }
}

my @SENT;          # [$target, $msg]
my %CHANSET_ON;    # "channel|Chanset" => 1

return sub {
    my ($assert) = @_;

    no warnings 'redefine';
    no warnings 'once';
    local *Mediabot::Helpers::botPrivmsg = sub { push @SENT, [ $_[1], $_[2] ]; 1 };
    local *Mediabot::Helpers::chanset_enabled = sub {
        my ($self, $channel, $name, %o) = @_;
        return $CHANSET_ON{"$channel|$name"} // $o{default} // 0;
    };
    # _onthisday_lines dépend du DBH ; on le mocke pour piloter le contenu
    my $LINES = [];
    local *Mediabot::UserCommands::_onthisday_lines = sub {
        my ($self, $id_channel, $label) = @_;
        return @{ $LINES };
    };

    my $mk = sub {
        my %chans = @_;
        return bless {
            logger   => L706->new,
            dbh      => 1,             # présence suffit (lines mockées)
            channels => { %chans },
        }, 'Mediabot';
    };

    # -------------------------------------------------------------------------
    # [1a] opt-in : un canal SANS le chanset ne reçoit rien
    # -------------------------------------------------------------------------
    {
        @SENT = (); %CHANSET_ON = ();
        $LINES = [ 'On this day on #x (2024-2025): 10 message(s) across 2 year(s).', '  2025: ...' ];
        my $bot = $mk->('#x' => Chan706->new(name => '#x', id => 1));
        my $n = Mediabot::post_onthisday_digest($bot);
        $assert->is($n, 0, '[1a] canal non opt-in -> aucun post');
        $assert->is(scalar(@SENT), 0, '[1a] rien envoyé');
    }

    # -------------------------------------------------------------------------
    # [1b] opt-in + historique -> en-tête + lignes postées sur le canal
    # -------------------------------------------------------------------------
    {
        @SENT = (); %CHANSET_ON = ('#x|OnThisDayDigest' => 1);
        $LINES = [
            'On this day on #x (2024-2025): 10 message(s) across 2 year(s).',
            '  2025: 7 msg, 3 people, most active: alice',
            'From 2025 — <alice> hello world',
        ];
        my $bot = $mk->('#x' => Chan706->new(name => '#x', id => 1));
        my $n = Mediabot::post_onthisday_digest($bot);
        $assert->is($n, 1, '[1b] 1 canal servi');
        my @to_x = grep { $_->[0] eq '#x' } @SENT;
        $assert->ok(scalar(@to_x) >= 4, '[1b] en-tête + 3 lignes postés');
        $assert->like($to_x[0][1], qr/On this day/, '[1b] en-tête en premier');
        $assert->like(join("\n", map { $_->[1] } @to_x), qr/most active: alice/, '[1b] contenu présent');
    }

    # -------------------------------------------------------------------------
    # [1c] opt-in mais AUCUN historique ce jour -> silence total
    # -------------------------------------------------------------------------
    {
        @SENT = (); %CHANSET_ON = ('#x|OnThisDayDigest' => 1);
        $LINES = [];   # _onthisday_lines vide
        my $bot = $mk->('#x' => Chan706->new(name => '#x', id => 1));
        my $n = Mediabot::post_onthisday_digest($bot);
        $assert->is($n, 0, '[1c] pas d\'historique -> aucun post');
        $assert->is(scalar(@SENT), 0, '[1c] silence total');
    }

    # -------------------------------------------------------------------------
    # [1d] multi-canaux : seuls les opt-in reçoivent
    # -------------------------------------------------------------------------
    {
        @SENT = (); %CHANSET_ON = ('#in|OnThisDayDigest' => 1);
        $LINES = [ 'On this day on X (2025): 5 message(s) across 1 year(s).' ];
        my $bot = $mk->(
            '#in'  => Chan706->new(name => '#in',  id => 1),
            '#out' => Chan706->new(name => '#out', id => 2),
        );
        my $n = Mediabot::post_onthisday_digest($bot);
        $assert->is($n, 1, '[1d] seul #in servi');
        $assert->ok((grep { $_->[0] eq '#in' } @SENT) > 0, '[1d] #in reçoit');
        $assert->is(scalar(grep { $_->[0] eq '#out' } @SENT), 0, '[1d] #out ne reçoit rien');
    }

    # -------------------------------------------------------------------------
    # [2] refactor : commande ET digest utilisent _onthisday_lines
    # -------------------------------------------------------------------------
    {
        my $uc = _slurp_706(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
        $assert->like($uc, qr/sub _onthisday_lines \{/, '[2] _onthisday_lines existe');
        $assert->like($uc, qr/Mediabot::UserCommands::_onthisday_lines\(\$self, \$id_channel, \$channel, %date_opts\)/,
            '[2] la commande délègue à _onthisday_lines (avec date optionnelle)');
        my $med = _slurp_706(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
        $assert->like($med, qr/Mediabot::UserCommands::_onthisday_lines\(\$self, \$id_channel, \$channel\)/,
            '[2] le digest délègue à _onthisday_lines');
        # garde projet : pas de publictext IS NOT NULL dans la fonction partagée
        my ($otd) = $uc =~ /(sub _onthisday_lines \{.*?\n\})/s; $otd //= '';
        $assert->unlike($otd, qr/publictext\s+IS\s+NOT\s+NULL/i, '[2] pas de publictext IS NOT NULL');
    }

    # -------------------------------------------------------------------------
    # [3] intégration : chanset, migration, tick calendar, heure configurable
    # -------------------------------------------------------------------------
    {
        my $sql = _slurp_706(File::Spec->catfile('.', 'install', 'mediabot.sql'));
        $assert->like($sql, qr/\(21,\s*'OnThisDayDigest'\)/, '[3] chanset id 21 au schéma');

        $assert->ok(-f File::Spec->catfile('.','install','migrations','20260708_onthisday_digest_chanset.sql'),
            '[3] migration présente');
        my $db = _slurp_706(File::Spec->catfile('.', 'docs', 'DB_MIGRATIONS.md'));
        $assert->like($db, qr/20260708_onthisday_digest_chanset\.sql/, '[3] migration déclarée');

        my $main = _slurp_706(File::Spec->catfile('.', 'mediabot.pl'));
        $assert->like($main, qr/name\s*=>\s*'onthisday_digest'/, '[3] tick onthisday_digest enregistré');
        $assert->like($main, qr/next_run_cb\s*=>\s*\$next_daily_at/, '[3] tick en mode calendar (quotidien)');
        $assert->like($main, qr/ONTHISDAY_DIGEST_HOUR/, '[3] heure configurable');
        $assert->like($main, qr/post_onthisday_digest/, '[3] cb appelle post_onthisday_digest');

        my $med = _slurp_706(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
        $assert->like($med, qr/default => 0/, '[3] digest OPT-IN (default 0)');
    }
};
