# t/cases/710_mb500_engagement_hardening.t
# =============================================================================
# mb500 — passe de consolidation de l'arc engagement.
#
# La revue a trouvé un vrai trou : !mood (enrichi en mb498 de 3 scans
# CHANNEL_LOG) n'avait NI garde $dbh NI cooldown, contrairement à onthisday.
#   -> $dbh undef faisait planter ("prepare on undefined") ;
#   -> pas de cooldown = flood/charge DB possible.
#
# Ce test verrouille :
#   [1] mood tolère un $dbh absent (message propre, pas de crash) ;
#   [2] mood a un cooldown par nick (2e appel rapide bloqué) ;
#   [3] cohérence de l'arc : onthisday, mood, seen protègent tous leur accès DB.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::UserCommands;
use Mediabot::Context;

sub _slurp_710 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{
    package L710; sub new { bless {}, shift } sub log { }
    package M710; sub new { bless {}, shift } sub inc { }
    package STH710;
    sub new { my ($c,%a)=@_; bless { %a, i=>0 }, $c }
    sub execute {
        my ($s,@b)=@_; $s->{i}=0; my $q=$s->{sql};
        if    ($q =~ /GROUP BY cl\.nick/)      { $s->{rows}=[{nick=>'a',c=>3}] }
        elsif ($q =~ /GROUP BY HOUR/)          { $s->{rows}=[{h=>20,c=>10}] }
        elsif ($q =~ /SELECT cl\.publictext/)  { $s->{rows}=[['salut cool']] }
        else                                    { $s->{rows}=[] }
        return 1;
    }
    sub fetchrow_arrayref { my $s=shift; return undef if $s->{i}>=@{$s->{rows}}; return $s->{rows}[$s->{i}++]; }
    sub fetchrow_hashref  { my $s=shift; return undef if $s->{i}>=@{$s->{rows}}; return $s->{rows}[$s->{i}++]; }
    sub finish { 1 }
    package DBH710; sub new { bless {}, shift } sub prepare { STH710->new(sql=>$_[1]) }
}

my @SENT;

return sub {
    my ($assert) = @_;

    no warnings 'redefine';
    no warnings 'once';
    local *Mediabot::UserCommands::botPrivmsg = sub { push @SENT, $_[2]; 1 };
    local *Mediabot::UserCommands::botNotice  = sub { push @SENT, "NOTICE: $_[2]"; 1 };

    # --- [1] mood tolère $dbh absent ---------------------------------------
    {
        @SENT = ();
        my $bot = bless {
            dbh => undef, logger => L710->new, metrics => M710->new,
            channels => {}, _mood_count => {}, _mood_cooldown => {},
        }, 'Mediabot';
        my $ctx = Mediabot::Context->new(bot=>$bot, nick=>'zoe', channel=>'#teuk',
            message=>'mood', args=>[]);
        my $ok = eval { Mediabot::UserCommands::mbMood_ctx($ctx); 1 };
        $assert->ok($ok, '[1] mood ne plante pas avec dbh undef');
        $assert->like(join("\n",@SENT), qr/database unavailable/, '[1] message propre "database unavailable"');
    }

    # --- [2] cooldown par nick ---------------------------------------------
    {
        @SENT = ();
        my $bot = bless {
            dbh => DBH710->new, logger => L710->new, metrics => M710->new,
            channels => {}, _mood_count => {}, _mood_cooldown => {}, achievements => undef,
        }, 'Mediabot';
        my $mk = sub {
            Mediabot::Context->new(bot=>$bot, nick=>'dave', channel=>'#teuk',
                message=>'mood', args=>[]);
        };
        eval { Mediabot::UserCommands::mbMood_ctx($mk->()) };   # 1er appel : ok
        @SENT = ();
        eval { Mediabot::UserCommands::mbMood_ctx($mk->()) };   # 2e appel : cooldown
        $assert->like(join("\n",@SENT), qr/please wait \d+s/, '[2] 2e appel rapide bloqué par cooldown');
        # un autre nick n'est PAS bloqué
        @SENT = ();
        my $ctx3 = Mediabot::Context->new(bot=>$bot, nick=>'erin', channel=>'#teuk',
            message=>'mood', args=>[]);
        eval { Mediabot::UserCommands::mbMood_ctx($ctx3) };
        $assert->unlike(join("\n",@SENT), qr/please wait/, '[2] cooldown est par-nick (erin passe)');
    }

    # --- [3] cohérence de l'arc : gardes DB partout ------------------------
    {
        my $src = _slurp_710(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));

        my ($mood) = $src =~ /(sub mbMood_ctx \{.*?\n\})/s; $mood //= '';
        $assert->like($mood, qr/unless \(\$dbh\) \{ botNotice.*database unavailable/s,
            '[3] mood: garde $dbh');
        $assert->like($mood, qr/_mood_cooldown/, '[3] mood: cooldown présent');

        my ($otd) = $src =~ /(sub mbOnThisDay_ctx \{.*?\n\})/s; $otd //= '';
        $assert->like($otd, qr/unless \(\$dbh\).*database unavailable/s, '[3] onthisday: garde $dbh');
        $assert->like($otd, qr/_otd_cooldown/, '[3] onthisday: cooldown présent');

        # seen : le compteur 24h (mb497) est best-effort (execute sous eval)
        my ($seen) = $src =~ /(sub mbSeen_ctx \{.*?\n\})/s; $seen //= '';
        $assert->like($seen, qr/eval \{ \$sth_act->execute/, '[3] seen: compteur 24h best-effort');
    }
};
