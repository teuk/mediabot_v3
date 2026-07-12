# t/cases/713_mb503_prerelease_fixes.t
# =============================================================================
# mb503 — passe de corrections pré-release 3.3.
#
#   [1] BUG cooldown : mbMilestone_ctx (2 scans CHANNEL_LOG) n'avait aucun
#       cooldown, contrairement à mood/onthisday -> ajouté (par-nick, 15s).
#   [2] BUG catégorie : en mb501, topquote/halloffame avaient été ajoutés au
#       MAUVAIS mapping (_mbHelpCategoryAliases, qui mappe des alias de
#       CATÉGORIES) au lieu de _mbHelpExplicitCategory (commande->catégorie).
#       Résultat : topquote tombait dans 'channel', halloffame dans 'general'.
#       Corrigé -> les deux dans 'ai_fun' avec les autres quotes.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::UserCommands;
use Mediabot::Context;
require Mediabot::Mediabot;

sub _slurp_713 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{
    package L713; sub new { bless {}, shift } sub log { }
    package Chan713; sub new { bless { id=>$_[1] }, $_[0] } sub get_id { $_[0]->{id} }
    package STH713;
    sub new { my ($c,%a)=@_; bless { %a, i=>0 }, $c }
    sub execute { my ($s,@b)=@_; $s->{i}=0;
        if    ($s->{sql} =~ /MIN\(ts\)/)       { $s->{rows}=[{total=>5000, first_ts=>'2020-01-01 00:00:00', first_uts=>1577836800}] }
        elsif ($s->{sql} =~ /INTERVAL 30 DAY/) { $s->{rows}=[{c=>300}] }
        else                                    { $s->{rows}=[] }
        return 1;
    }
    sub fetchrow_hashref { my $s=shift; return undef if $s->{i}>=@{$s->{rows}}; return $s->{rows}[$s->{i}++]; }
    sub finish { 1 }
    package DBH713; sub new { bless {}, shift } sub prepare { STH713->new(sql=>$_[1]) }
}

my @SENT;

return sub {
    my ($assert) = @_;

    no warnings 'redefine';
    no warnings 'once';
    local *Mediabot::UserCommands::botPrivmsg = sub { push @SENT, $_[2]; 1 };
    local *Mediabot::UserCommands::botNotice  = sub { push @SENT, "NOTICE: $_[2]"; 1 };
    local *Mediabot::UserCommands::isIrcChannelTarget = sub { defined $_[0] && $_[0] =~ /^[#&]/ };

    # --- [1] cooldown milestone --------------------------------------------
    {
        my $bot = bless {
            dbh => DBH713->new, logger => L713->new,
            channels => { '#teuk' => Chan713->new(42) }, _milestone_cooldown => {},
        }, 'Mediabot';
        my $mk = sub {
            Mediabot::Context->new(bot=>$bot, nick=>'dave', channel=>'#teuk',
                message=>'milestone', args=>[]);
        };
        @SENT = ();
        Mediabot::UserCommands::mbMilestone_ctx($mk->());   # 1er : ok
        my $first_lines = scalar @SENT;
        $assert->ok($first_lines >= 2, '[1] 1er appel produit la sortie milestone');
        @SENT = ();
        Mediabot::UserCommands::mbMilestone_ctx($mk->());   # 2e rapide : cooldown
        $assert->like(join("\n",@SENT), qr/please wait \d+s/, '[1] 2e appel rapide bloqué (cooldown)');
        # autre nick : pas bloqué
        @SENT = ();
        my $ctx2 = Mediabot::Context->new(bot=>$bot, nick=>'erin', channel=>'#teuk',
            message=>'milestone', args=>[]);
        Mediabot::UserCommands::mbMilestone_ctx($ctx2);
        $assert->unlike(join("\n",@SENT), qr/please wait/, '[1] cooldown par-nick (erin passe)');

        # garde source : le pattern cooldown existe
        my $uc = _slurp_713(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
        my ($fn) = $uc =~ /(sub mbMilestone_ctx \{.*?\n\})/s; $fn //= '';
        $assert->like($fn, qr/_milestone_cooldown/, '[1] bucket _milestone_cooldown présent');
    }

    # --- [2] catégorisation topquote/halloffame ----------------------------
    {
        my %cats = Mediabot::_mbHelpBuildCategories();
        my $cat_of = sub {
            my ($cmd) = @_;
            for my $c (sort keys %cats) { return $c if grep { $_ eq $cmd } @{$cats{$c}}; }
            return '?';
        };
        $assert->is($cat_of->('topquote'),   'ai_fun', '[2] topquote -> ai_fun');
        $assert->is($cat_of->('halloffame'), 'ai_fun', '[2] halloffame -> ai_fun');

        # le mapping explicite (commande->catégorie) les contient désormais
        my %explicit = Mediabot::_mbHelpExplicitCategory();
        $assert->is($explicit{topquote},   'ai_fun', '[2] topquote dans ExplicitCategory');
        $assert->is($explicit{halloffame}, 'ai_fun', '[2] halloffame dans ExplicitCategory');

        # et NE sont PLUS dans le mapping d'alias de catégories
        my %aliases = Mediabot::_mbHelpCategoryAliases();
        $assert->ok(!exists $aliases{topquote},   '[2] topquote retiré de CategoryAliases');
        $assert->ok(!exists $aliases{halloffame}, '[2] halloffame retiré de CategoryAliases');
    }
};
