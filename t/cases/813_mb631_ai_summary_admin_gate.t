# t/cases/813_mb631_ai_summary_admin_gate.t
# =============================================================================
# mb631 — 'ai summary' passe Administrator, sous TOUTES ses formes.
#
# DEMANDE teuk : « serait-il possible de restreindre l'acces a m ai summary
# (sous toutes ses formes) au niveau Administrator ». Le resume lit
# l'historique complet d'un salon et le fait ressortir reformule : c'est une
# capacite de moderation, pas un jouet de salon.
#
#   [1] canal ET prive : les deux passent par claude_ctx, la porte y est
#       posee AVANT tout traitement — y compris avant 'help', sinon la
#       sous-commande se documenterait elle-meme a qui n'y a pas droit.
#   [2] partyline : meme porte, avec l'echelle INVERSEE de la partyline
#       (Owner=0, Master=1, Administrator=2 -> « level <= 2 »).
#   [3] un appelant non autorise n'atteint AUCUN traitement du summary ni
#       CHANNEL_LOG : require_level peut naturellement resoudre l'identite,
#       puis la branche rend la main immediatement.
#   [4] les autres sous-commandes de !ai ne sont PAS touchees.
#   [5] les trois aides annoncent le niveau requis.
#   [6] BONUS — faux positif corrige dans la garde anti-mojibake du test 804 :
#       « â » seul est une lettre francaise legitime, et le tirage de
#       l'horoscope dependant de la DATE, la suite virait au rouge certains
#       jours pour une sortie parfaitement correcte.
# =============================================================================

use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

{
    package CtxGate;
    sub new { my ($c,%a)=@_; bless { %a, asked => [] }, $c }
    sub bot { $_[0]{bot} } sub nick { 'teuk' } sub channel { '#c' }
    sub args { $_[0]{args} } sub message { {} }
    sub require_level {
        my ($self, $level) = @_;
        push @{ $self->{asked} }, $level;
        return $self->{allow} ? 1 : 0;
    }
}
{ package LogGate; sub new { bless {}, shift } sub log { 1 } }
{ package DbhGate; sub new { bless { used => 0 }, shift }
  sub prepare { $_[0]{used}++; return undef } }
{ package StreamGate;
  sub new { bless { out => [] }, shift }
  sub write { my ($self,$txt)=@_; push @{ $self->{out} }, $txt; 1 }
  sub text { join('', @{ $_[0]{out} }) }
}

return sub {
    my ($assert) = @_;

    require Mediabot::External::Claude;
    require Mediabot::Partyline;

    my $src  = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/External/Claude.pm'
        or die $!; local $/; <$fh> };
    my $pl   = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/Partyline.pm'
        or die $!; local $/; <$fh> };
    $pl .= "\n" . do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/Partyline/Commands.pm'
        or die $!; local $/; <$fh> };
    my $disp = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/Mediabot.pm'
        or die $!; local $/; <$fh> };

    # [1] la porte est le PREMIER geste de la branche summary
    $assert->like($src,
        qr/if \(\@args && lc\(\$args\[0\]\) eq 'summary'\) \{.{0,600}?require_level\('Administrator'\)/s,
        'mb631-813: la branche summary commence par la porte');
    my ($branch) = $src =~ /if \(\@args && lc\(\$args\[0\]\) eq 'summary'\) \{(.*?)\n        shift \@args;/s;
    $assert->ok(defined $branch && $branch =~ /require_level/,
        'mb631-813: ... avant meme de consommer les arguments');
    $assert->ok(defined $branch && $branch !~ /want_help|_summary_parse|prepare/,
        'mb631-813: ... et avant toute aide ou lecture CHANNEL_LOG');

    # [3] un refus rend la main avant toute lecture CHANNEL_LOG / summary
    my $dbh = DbhGate->new;
    my $bot = bless { dbh => $dbh, logger => LogGate->new }, 'Mediabot';
    my @out;
    no warnings 'redefine';
    local *Mediabot::Helpers::botNotice  = sub { push @out, $_[2]; 1 };
    local *Mediabot::Helpers::botPrivmsg = sub { push @out, $_[2]; 1 };
    local *Mediabot::Helpers::isIrcChannelTarget = sub { 1 };
    local *Mediabot::Helpers::channel_lang = sub { 'en' };

    my $ctx = CtxGate->new(bot => $bot, allow => 0, args => [ 'summary', 'today' ]);
    Mediabot::External::Claude::claude_ctx($ctx);
    $assert->is(join(',', @{ $ctx->{asked} }), 'Administrator',
        'mb631-813: le niveau demande est bien Administrator');
    $assert->is($dbh->{used}, 0,
        'mb631-813: un refus ne touche PAS la DB du summary');
    $assert->is(scalar @out, 0,
        'mb631-813: ... et ne produit aucune sortie (require_level parle deja)');

    # meme chose pour 'help' : la sous-commande ne se documente pas a qui n a pas droit
    my $ctx_help = CtxGate->new(bot => $bot, allow => 0, args => [ 'summary', 'help' ]);
    Mediabot::External::Claude::claude_ctx($ctx_help);
    $assert->is(scalar @out, 0,
        'mb631-813: « summary help » est garde comme le reste');
    $assert->is(scalar @{ $ctx_help->{asked} }, 1,
        'mb631-813: ... par la meme porte, une seule fois');

    # [2] partyline : echelle inversee
    $assert->like($pl, qr/if \(\$subcmd eq 'summary'\) \{.{0,400}?\$pl_level <= 2/s,
        'mb631-813: la partyline exige Administrator ou mieux');
    $assert->like($pl, qr/Permission denied \(Administrator\+ required\)/,
        'mb631-813: ... avec un refus explicite');
    $assert->like($pl, qr/Owner=0, Master=1, Administrator=2/,
        'mb631-813: ... et l echelle inversee est documentee sur place');

    # La porte partyline est aussi exercee, pas seulement relue dans le source.
    my $pl_bot = bless { channels => {} }, 'BotGate';
    my $pl_obj = bless {
        bot   => $pl_bot,
        users => { 42 => { login => 'teuk', level => 3 } },
    }, 'Mediabot::Partyline';
    my $denied = StreamGate->new;
    $pl_obj->_cmd_ai($denied, 42, 'summary 10');
    $assert->like($denied->text, qr/Permission denied \(Administrator\+ required\)/,
        'mb631-813: partyline User est refuse au runtime');

    $pl_obj->{users}{42}{level} = 2;
    my $allowed = StreamGate->new;
    $pl_obj->_cmd_ai($allowed, 42, 'summary 10');
    $assert->ok($allowed->text !~ /Permission denied/ && $allowed->text =~ /No IRC channel available/,
        'mb631-813: partyline Administrator franchit la porte au runtime');

    # [4] les autres sous-commandes restent libres
    for my $sub (qw(forget models stats reset history pin)) {
        my ($blk) = $src =~ /eq '\Q$sub\E'\) \{(.{0,200})/s;
        $assert->ok(defined $blk,
            "mb631-813: la sous-commande '$sub' existe toujours");
        $assert->ok(defined($blk) && $blk !~ /require_level/,
            "mb631-813: la sous-commande '$sub' n est pas restreinte");
    }

    # [5] les trois aides annoncent le niveau
    # mb636: la ligne annonce aussi le niveau supplementaire du croisement.
    $assert->like($disp, qr/summary \(Administrator\+; Master\+ to publish another channel here\)/,
        'mb631-813: la ligne de commande publique l annonce');
    my @usage = Mediabot::External::Claude::_summary_usage();
    $assert->ok((grep { /Administrator\+/ } @usage),
        'mb631-813: l aide de la sous-commande l annonce');
    $assert->like($pl, qr/summary \[Administrator\+\]/,
        'mb631-813: l aide de la partyline l annonce');

    # [6] la garde anti-mojibake ne se declenche plus sur un circonflexe
    my $w = do { open my $fh, '<:encoding(UTF-8)', 't/cases/804_mb621_wire_encoding.t'
        or die $!; local $/; <$fh> };
    $assert->ok($w !~ qr/\!~ \/Ã©\|Ã¨\|Ã \|â\//,
        'mb631-813: l alternative « â » seul a disparu du test 804');
    $assert->like($w, qr/la garde reconnait toujours un double encodage reel/,
        'mb631-813: ... remplacee par une garde qui prouve qu elle mord encore');
    my $re = qr/Ã[\x80-\xBF\xA0-\xFF]|â€|Â[\x80-\xBF\xA0-\xBF]/;
    $assert->ok('une tâche, des âmes, il bâtis' !~ $re,
        'mb631-813: les circonflexes francais passent');
    $assert->ok("humeur \x{C3}\x{A9}lectrique" =~ $re,
        'mb631-813: un vrai double encodage est toujours attrape');
};
