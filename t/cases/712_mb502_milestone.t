# t/cases/712_mb502_milestone.t
# =============================================================================
# mb502 — !milestone / !milestones : les paliers du canal. Total des messages
# publics loggés, prochain palier rond, progression + ETA au rythme récent,
# et un rappel de l'ancienneté du canal.
#
#   [1] helpers : _milestone_next (pas adaptatif), _group_int, _humanize_days ;
#   [2] mbMilestone_ctx : rendu complet, cas vide, garde canal/dbh ;
#   [3] intégration : dispatch (milestone+milestones), help, catégorie.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::UserCommands;
use Mediabot::Context;

sub _slurp_712 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }
sub _strip { my ($s)=@_; $s =~ s/\x03\d{0,2}(?:,\d{1,2})?|\x0f|\x02//g; return $s; }

{
    package L712; sub new { bless {}, shift } sub log { }
    package Chan712; sub new { bless { id=>$_[1] }, $_[0] } sub get_id { $_[0]->{id} }
    package STH712;
    sub new { my ($c,%a)=@_; bless { %a, i=>0 }, $c }
    sub execute { my ($s,@b)=@_; $s->{i}=0;
        if    ($s->{sql} =~ /MIN\(ts\)/)        { $s->{rows} = $s->{data}{tot} }
        elsif ($s->{sql} =~ /INTERVAL 30 DAY/)  { $s->{rows} = $s->{data}{rate} }
        else                                    { $s->{rows} = [] }
        return 1;
    }
    sub fetchrow_hashref { my $s=shift; return undef if $s->{i}>=@{$s->{rows}}; return $s->{rows}[$s->{i}++]; }
    sub finish { 1 }
    package DBH712;
    sub new { bless { data=>$_[1] }, $_[0] }
    sub prepare { STH712->new(sql=>$_[1], data=>$_[0]->{data}) }
}

my @SENT;

return sub {
    my ($assert) = @_;

    no warnings 'redefine';
    no warnings 'once';
    local *Mediabot::UserCommands::botPrivmsg = sub { push @SENT, $_[2]; 1 };
    local *Mediabot::UserCommands::botNotice  = sub { push @SENT, "NOTICE: $_[2]"; 1 };
    local *Mediabot::UserCommands::isIrcChannelTarget = sub { defined $_[0] && $_[0] =~ /^[#&]/ };

    # --- [1] helpers --------------------------------------------------------
    {
        $assert->is(Mediabot::UserCommands::_milestone_next(500),    1000,   '[1] next: 500 -> 1000');
        $assert->is(Mediabot::UserCommands::_milestone_next(3500),   4000,   '[1] next: 3500 -> 4000 (pas 1k)');
        $assert->is(Mediabot::UserCommands::_milestone_next(12000),  15000,  '[1] next: 12000 -> 15000 (pas 5k)');
        $assert->is(Mediabot::UserCommands::_milestone_next(99000),  100000, '[1] next: 99000 -> 100000');
        $assert->is(Mediabot::UserCommands::_milestone_next(100000), 150000, '[1] next: 100000 -> 150000 (pas 50k)');
        $assert->is(Mediabot::UserCommands::_milestone_next(1234567),1300000,'[1] next: 1.23M -> 1.3M (pas 100k)');

        $assert->is(Mediabot::UserCommands::_group_int(1234567), '1,234,567', '[1] group: séparateurs');
        $assert->is(Mediabot::UserCommands::_group_int(0),       '0',         '[1] group: 0');
        $assert->is(Mediabot::UserCommands::_group_int(999),     '999',       '[1] group: <1000');

        $assert->is(Mediabot::UserCommands::_humanize_days(5),   '5 days',    '[1] human: 5 days');
        $assert->is(Mediabot::UserCommands::_humanize_days(1),   '1 day',     '[1] human: singulier');
        $assert->like(Mediabot::UserCommands::_humanize_days(90),  qr/months/,'[1] human: mois');
        $assert->like(Mediabot::UserCommands::_humanize_days(800), qr/years/, '[1] human: années');
    }

    my $mk = sub {
        my ($data) = @_;
        bless {
            dbh => DBH712->new($data), logger => L712->new,
            channels => { '#teuk' => Chan712->new(42) },
        }, 'Mediabot';
    };

    # --- [2] rendu complet --------------------------------------------------
    {
        @SENT = ();
        my $bot = $mk->({
            tot  => [ { total=>98750, first_ts=>'2019-03-15 12:00:00', first_uts=>1552651200 } ],
            rate => [ { c=>9000 } ],   # 300/j
        });
        my $ctx = Mediabot::Context->new(bot=>$bot, nick=>'t', channel=>'#teuk',
            message=>'milestone', args=>[]);
        Mediabot::UserCommands::mbMilestone_ctx($ctx);
        my $all = join("\n", map { _strip($_) } @SENT);
        $assert->like($all, qr/#teuk: 98,750 public messages logged/, '[2] total groupé');
        $assert->like($all, qr/next milestone: 100,000 \(1,250 to go, 98%\)/, '[2] palier + progression');
        $assert->like($all, qr/300 msg\/day/, '[2] rythme récent');
        $assert->like($all, qr/logging since 2019-03-15/, '[2] date de début');
        $assert->like($all, qr/lifetime average \d+ msg\/day/, '[2] moyenne long terme');
    }

    # --- [2b] canal vide ----------------------------------------------------
    {
        @SENT = ();
        my $bot = $mk->({ tot => [ { total=>0, first_ts=>undef, first_uts=>undef } ], rate => [ {c=>0} ] });
        my $ctx = Mediabot::Context->new(bot=>$bot, nick=>'t', channel=>'#teuk',
            message=>'milestone', args=>[]);
        Mediabot::UserCommands::mbMilestone_ctx($ctx);
        $assert->like(join("\n",@SENT), qr/journey starts now/, '[2b] message si aucun message');
    }

    # --- [2c] gardes --------------------------------------------------------
    {
        @SENT = ();
        my $bot = $mk->({ tot=>[], rate=>[] });
        my $ctx = Mediabot::Context->new(bot=>$bot, nick=>'t', channel=>undef,
            message=>'milestone', args=>[]);
        Mediabot::UserCommands::mbMilestone_ctx($ctx);
        $assert->like(join("\n",@SENT), qr/NOTICE:.*use it in a channel/, '[2c] refus hors canal');

        @SENT = ();
        my $nodb = bless { dbh=>undef, logger=>L712->new, channels=>{} }, 'Mediabot';
        my $ctx2 = Mediabot::Context->new(bot=>$nodb, nick=>'t', channel=>'#teuk',
            message=>'milestone', args=>[]);
        Mediabot::UserCommands::mbMilestone_ctx($ctx2);
        $assert->like(join("\n",@SENT), qr/database unavailable/, '[2c] garde dbh');
    }

    # --- [3] intégration ----------------------------------------------------
    {
        my $uc = _slurp_712(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
        $assert->like($uc, qr/^\s*mbMilestone_ctx\s*$/m, '[3] mbMilestone_ctx exporté');
        my ($fn) = $uc =~ /(sub mbMilestone_ctx \{.*?\n\})/s; $fn //= '';
        $assert->like($fn, qr/event_type IN \('public','action'\)/, '[3] convention event_type');
        $assert->like($fn, qr/\$self->\{channels\}\{lc \$channel\}/, '[3] lookup canal en lc (garde 625)');

        my $med = _slurp_712(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
        $assert->like($med, qr/milestone\s*=>\s*sub\s*\{\s*mbMilestone_ctx/, '[3] milestone au dispatch');
        $assert->like($med, qr/milestones\s*=>\s*sub\s*\{\s*mbMilestone_ctx/, '[3] alias milestones');
        $assert->like($med, qr/^milestone\|milestone\|public/m, '[3] milestone documenté');
        $assert->like($med, qr/milestone\s*=>\s*'stats'/, '[3] milestone catégorisé stats');
    }
};
