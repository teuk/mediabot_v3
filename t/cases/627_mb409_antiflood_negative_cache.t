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
use Mediabot::Channel::FloodRules ();
use Scalar::Util qw(refaddr);
use Storable qw(dclone);
use JSON::PP ();
{ package MB1209::Log; sub log {1}
  package MB1209::Channel; sub get_id {42}
  package MB1209::DB;
  sub prepare { my ($s,$sql)=@_; $s->{selects}++; $s->{sql}=$sql; return $s }
  sub execute { $_[0]{bound}=$_[1]; 1 }
  sub fetchrow_hashref { undef }
  sub finish { $_[0]{finished}++; 1 }
}
{
  package MB1210::DB;
  sub step {
    my ($s,$op,@args)=@_; push @{$s->{calls}},[$op,@args];
    die $s->{exception} if ($s->{throw}//'') eq $op;
    return 0 if ($s->{false}//'') eq $op;
    return 1;
  }
  sub prepare {my($s,$sql)=@_;$s->step('prepare',$sql) ? $s : undef}
  sub execute {my($s,@args)=@_;$s->step('execute',@args)}
  sub fetchrow_hashref {my($s)=@_;$s->step('fetch');$s->{row}}
  sub finish {my($s)=@_;$s->step('finish')}
}
return sub {
    my ($assert) = @_;
    my $json=JSON::PP->new->canonical;
    my $deep=sub {my($got,$want,$label)=@_;$assert->is($json->encode($got),$json->encode($want),$label)};
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
    # MB1210: native read boundary and admission/cache failure policy.
    my $sql='SELECT nbmsg_max, duration, timetowait FROM CHANNEL_FLOOD WHERE id_channel = ?';
    my $calls=[['prepare',$sql],['execute',42],['fetch'],['finish']];
    for my $row (undef, {}, {nbmsg_max=>0,duration=>undef,timetowait=>12}) {
        my $handle=bless {calls=>[],row=>$row},'MB1210::DB';
        my $result=Mediabot::Channel::FloodRules::read($handle,42);
        $assert->is($result->{status},defined($row)?'found':'missing','reader distinguishes missing and configured rows');
        $assert->is(refaddr($result->{row})//0,refaddr($row)//0,'reader preserves row identity and raw values');
        $deep->($handle->{calls},$calls,'reader binds ID and preserves successful statement order');
    }
    for my $op (qw(prepare execute)) {
        my $handle=bless {calls=>[],false=>$op},'MB1210::DB';
        # Replace only the scalar slot; never assign to DBI's read-only magic.
        no warnings 'once'; my $diagnostic='read fault';
        local *DBI::errstr=\$diagnostic;
        my $result=Mediabot::Channel::FloodRules::read($handle,42);
        $deep->($result,{status=>'error',error=>'read fault'},'false DB result remains an error, not missing configuration');
        $deep->($handle->{calls},[ @{$calls}[0..($op eq 'prepare'?0:1)] ],'false read retains historical statement call order');
    }
    for my $op (qw(prepare execute fetch finish)) {
        my $exception=bless {},'MB1210::Exception';
        my $handle=bless {calls=>[],throw=>$op,exception=>$exception},'MB1210::DB';
        my $error; {local $@;eval {Mediabot::Channel::FloodRules::read($handle,42)};$error=$@}
        $assert->is(refaddr($error),refaddr($exception),"$op exception propagates without replacement");
        my %last=(prepare=>0,execute=>1,fetch=>2,finish=>3);
        $deep->($handle->{calls},[ @{$calls}[0..$last{$op}] ],'exception stops at the same statement operation');
    }
    # A failed refresh retains confirmed cache bytes/age, admits globally, and
    # retries next time. Never turn an error into a successful negative cache.
    for my $op (qw(prepare execute)) {
        $now=2000;
        my $handle=bless {calls=>[],false=>$op,row=>{nbmsg_max=>5,duration=>30,timetowait=>15}},'MB1210::DB';
        my $old={ts=>1000,nbmsg_max=>0,duration=>30,timetowait=>15};
        my $subject={dbh=>$handle,logger=>bless({},'MB1209::Log'),
          channels=>{'#teuk'=>bless({},'MB1209::Channel')},_af_params=>{'#teuk'=>dclone($old)}};
        # Replace only the scalar slot; never assign to DBI's read-only magic.
        no warnings 'once'; my $diagnostic='read fault';
        local *DBI::errstr=\$diagnostic;
        $assert->is(Mediabot::IRC::OutputPolicy::checkAntiFlood($subject,'#teuk',1,$hooks),0,'failed refresh retains global-only admission');
        $deep->($subject->{_af_params}{'#teuk'},$old,'failed refresh preserves confirmed values and their original age');
        $assert->is(scalar @{$subject->{_global_af}{hits}},1,'failed refresh admission still spends global allowance');
        $handle->{false}='';$handle->{calls}=[];
        $assert->is(Mediabot::IRC::OutputPolicy::checkAntiFlood($subject,'#teuk',1,$hooks),0,'next attempt immediately retries and accepts successful refresh');
        $deep->($handle->{calls},$calls,'recovery really reads the database again');
        $assert->is($subject->{_af_params}{'#teuk'}{ts},$now,'only successful recovery advances cache age');
        $handle->{calls}=[];
        Mediabot::IRC::OutputPolicy::checkAntiFlood($subject,'#teuk',1,$hooks);
        $deep->($handle->{calls},[],'fresh confirmed rules avoid another SQL read');
    }

};
