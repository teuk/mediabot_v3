# t/cases/337_antiflood_output_cache_and_metrics.t
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use Mediabot::IRC::OutputPolicy ();
{
 package MB1170::Guard;
 our $now = 1800000000;
 sub checkAntiFlood {
  my ($bot, $channel, $cost) = @_;
  return Mediabot::IRC::OutputPolicy::checkAntiFlood($bot, $channel, $cost, {
   clock => sub { $now },
   config_int => sub { my ($s,$k,$d)=@_; return $k eq 'OUTPUT_GLOBAL_MAX_MSG' ? 5 : $d },
   reply => sub {1}, console => sub {1},
  });
 }
}

{ package MB1170::Log; sub log {1} }


sub _slurp_337 {
    open my $fh, '<:raw', $_[0] or die $!;
    local $/;
    return <$fh>;
}

sub _sub_337 {
    my ($src, $name) = @_;
    my $re = qr/^[ \t]*sub[ \t]+\Q$name\E\b[^{]*\{/m;
    return undef unless $src =~ /$re/g;
    my ($start, $pos, $depth) = ($-[0], pos($src), 1);
    while ($pos < length($src)) {
        my $ch = substr($src, $pos, 1);
        $depth++ if $ch eq '{';
        $depth-- if $ch eq '}';
        return substr($src, $start, $pos + 1 - $start) if $depth == 0;
        $pos++;
    }
    return undef;
}

return sub {
    my ($assert) = @_;

    my $helpers = _slurp_337(File::Spec->catfile('.', 'Mediabot', 'IRC', 'OutputPolicy.pm'));
    my $metrics = _slurp_337(File::Spec->catfile('.', 'Mediabot', 'Metrics.pm'));
    my $body = _sub_337($helpers, 'checkAntiFlood');

    $assert->ok(defined $body, 'checkAntiFlood body found');
    $assert->like($body // '', qr/OUTPUT_PARAMS_CACHE_TTL/,
        'checkAntiFlood uses configurable params cache TTL');
    $assert->like($body // '', qr/_af_params/,
        'checkAntiFlood caches CHANNEL_FLOOD params in _af_params');
    $assert->like($body // '', qr/_af\b/,
        'checkAntiFlood stores output flood state in _af');
    $assert->like($body // '', qr/SELECT\s+nbmsg_max,\s*duration,\s*timetowait\s+FROM\s+CHANNEL_FLOOD/s,
        'checkAntiFlood still reads existing CHANNEL_FLOOD schema');
    $assert->like($body // '', qr/mediabot_antiflood_blocks_total/,
        'checkAntiFlood increments output antiflood metric');

    for my $metric (qw(
        mediabot_antiflood_blocks_total
        mediabot_nickflood_blocks_total
        mediabot_chanflood_blocks_total
    )) {
        $assert->like($metrics, qr/\Q$metric\E/, "Metrics.pm declares $metric");
    }
    {
        $MB1170::Guard::now = 1800000000;
        my $bot={logger=>bless({},'MB1170::Log'),
            _af_params=>{'#busy'=>{ts=>$MB1170::Guard::now,nbmsg_max=>1,duration=>30,timetowait=>300},
                          '#quiet'=>{ts=>$MB1170::Guard::now,unconfigured=>1}}};
        require Mediabot::IRC::OutputBudget;
        no warnings 'redefine';
        local *Mediabot::IRC::OutputBudget::now=sub {$MB1170::Guard::now};
        my $check=\&MB1170::Guard::checkAntiFlood;
        $assert->is($check->($bot,'#busy'),0,'mb1170: first channel admission uses one global slot');
        $assert->is($check->($bot,'#busy'),1,'mb1170: channel limit still blocks the next attempt');
        my @blocked=map {$check->($bot,'#busy')} 1..20;
        $assert->is(join(',',@blocked),join(',',(1)x20),'mb1170: local silence remains enforced on every retry');
        $assert->is(scalar @{$bot->{_global_af}{hits}},1,'mb1170: rejected retries do not consume global output slots');
        $assert->is($bot->{_global_af}{silenced_until},0,'mb1170: rejected retries cannot silence other channels');
        my @allowed=map {$check->($bot,'#quiet')} 1..4;
        $assert->is(join(',',@allowed),'0,0,0,0','mb1170: another channel retains the remaining global allowance');
        $assert->is($check->($bot,'#quiet'),1,'mb1170: genuine global exhaustion still blocks admission');
        $assert->is(scalar @{$bot->{_global_af}{hits}},5,'mb1170: failed global admission does not add a phantom hit');
        $MB1170::Guard::now += 15;
        $assert->is($check->($bot,'#quiet'),0,'mb1170: existing global silence expires at its deadline');
        $assert->is(scalar @{$bot->{_global_af}{hits}},1,'mb1170: expired global hits are reclaimed before new admission');
    }

};
