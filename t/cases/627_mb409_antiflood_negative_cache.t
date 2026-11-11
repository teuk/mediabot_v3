# t/cases/627_mb409_antiflood_negative_cache.t
# =============================================================================
# mb409 — checkAntiFlood met en cache l'ABSENCE de configuration.
#
# Sans ligne CHANNEL_FLOOD (le cas par défaut d'un canal sans antiflood), le
# résultat n'était pas mémorisé : le SELECT était relancé à CHAQUE message
# sortant — à rebours de l'objectif AF1 « zero DB queries per outgoing
# message ». mb409 : cache négatif { ts, unconfigured } avec le même TTL que
# les paramètres ; le chemin chaud court-circuite sans SQL ; activer
# l'antiflood en base est pris en compte au prochain rafraîchissement.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use Mediabot::IRC::OutputPolicy ();
{ package MB1209::Log; sub log {1}
  package MB1209::Channel; sub get_id {42}
  package MB1209::DB;
  sub prepare { my ($s,$sql)=@_; $s->{selects}++; $s->{sql}=$sql; return $s }
  sub execute { $_[0]{bound}=$_[1]; 1 }
  sub fetchrow_hashref { undef }
  sub finish { $_[0]{finished}++; 1 }
}
return sub {
    my ($assert) = @_;
    my $db = bless {selects=>0,finished=>0}, 'MB1209::DB';
    my $bot = {dbh=>$db,logger=>bless({},'MB1209::Log'),
               channels=>{'#teuk'=>bless({},'MB1209::Channel')}};
    my $now;
    my $hooks = {clock=>sub {$now},config_int=>sub {$_[2]},
                 reply=>sub {die 'unexpected reply'},console=>sub {die 'unexpected console'}};
    my $check = sub {
        ($now)=@_;
        return Mediabot::IRC::OutputPolicy::checkAntiFlood($bot,'#teuk',undef,$hooks);
    };
    my @result = map {$check->(1000+$_)} 1..10;
    $assert->is(join(',',@result),join(',',(0)x10),'unconfigured channel admits every message');
    $assert->is($db->{selects},1,'10 messages use one SELECT');
    $check->(1060);
    $assert->is($db->{selects},1,'negative cache remains fresh before exact TTL');
    $check->(1061);
    $assert->is($db->{selects},2,'negative cache refreshes at exact TTL');
    $check->(1062);
    $assert->is($db->{selects},2,'negative cache starts a new lifetime');
    $assert->is($db->{finished},2,'both real policy reads finish their statements');
    $assert->is($db->{bound},42,'real policy binds the channel ID');
    $assert->is($bot->{_af_params}{'#teuk'}{unconfigured},1,'absence is cached in shared bot state');
};
