use strict;
use warnings;
use Test::More;
use Storable qw(dclone);
use POSIX qw(isfinite);
use Mediabot::Metrics;

{
    package MB847NoCoercion;
    use overload '""'=>sub {die 'must not stringify reference'}, '0+'=>sub {die 'must not coerce reference'}, fallback=>1;
}
sub metrics847 {
    my $m=Mediabot::Metrics->new(enabled=>1);
    $m->declare('mb847_gauge','gauge','finite gauge');
    $m->declare('mb847_counter','counter','finite counter');
    $m->declare('mb847_hist','histogram','finite histogram',buckets=>[.1,.5,1]);
    return $m;
}
for my $value ('1e999','-1e999','NaN','Inf','Infinity',"12\ninjected_sample 1",{},[],bless({},'MB847NoCoercion')) {
    my $m=metrics847();my $labels={channel=>'#test'};
    $m->set('mb847_gauge',42,$labels);$m->set('mb847_counter',7,$labels);$m->observe('mb847_hist',.25,$labels);
    my $before=dclone($m->get('mb847_hist',$labels));my (@warnings,@result);
    {
        local $SIG{__WARN__}=sub {push @warnings,shift};
        ok(eval {@result=($m->set('mb847_gauge',$value,$labels),$m->add('mb847_counter',$value,$labels),
            $m->observe('mb847_hist',$value,$labels));1},'invalid sample is contained without coercing reference');
    }
    ok(!(grep {$_} @result),'all three numeric mutation paths refuse invalid sample');
    my $seen=$m->get('mb847_gauge',$labels);
    is(ref($seen)?'invalid reference':$seen,42,'invalid set preserves previous gauge');
    is($m->get('mb847_counter',$labels),7,'invalid addition preserves previous counter');
    is_deeply($m->get('mb847_hist',$labels),$before,'invalid observation preserves all histogram state');
    is(scalar @warnings,0,'invalid sample produces no numeric warning');
}
for my $method (qw(set add inc)) {
    my $m=metrics847();my $labels={channel=>'#test'};$m->observe('mb847_hist',.25,$labels);
    my $before=dclone($m->get('mb847_hist',$labels));my $accepted;
    ok(eval {$accepted=$method eq 'inc' ? $m->inc('mb847_hist',$labels) : $m->$method('mb847_hist',1,$labels);1},
        "$method: scalar mutation of a histogram is contained");
    ok(!$accepted,"$method: histogram refuses scalar mutation");
    is_deeply($m->get('mb847_hist',$labels),$before,"$method: histogram remains intact");
    ok(eval {$m->observe('mb847_hist',.5,$labels);1},"$method: later observation still works");
    my $h=$m->get('mb847_hist',$labels);
    is(ref($h) eq 'HASH'?$h->{count}:undef,2,"$method: later observation increments the original histogram");
}
{
    my $m=metrics847();my $labels={channel=>'#overflow'};
    ok($m->set('mb847_gauge','1e308',$labels),'large finite gauge is accepted');
    ok(isfinite($m->get('mb847_gauge',$labels)),'accepted large sample is actually finite');
    ok(!$m->add('mb847_gauge','1e308',$labels),'overflowing scalar sum is refused');
    is($m->get('mb847_gauge',$labels),0+'1e308','overflowing addition preserves last finite scalar');
    ok($m->add('mb847_gauge','-1e308',$labels),'finite cancellation still succeeds');
    is($m->get('mb847_gauge',$labels),0,'negative gauge delta is preserved');
    ok($m->observe('mb847_hist','1e308',$labels),'large finite observation is accepted');
    my $before=dclone($m->get('mb847_hist',$labels));
    ok(!$m->observe('mb847_hist','1e308',$labels),'overflowing histogram sum is refused');
    is_deeply($m->get('mb847_hist',$labels),$before,'overflow does not partially increment histogram buckets/count');
    ok($m->observe('mb847_hist','-1e308',$labels),'negative finite generic histogram sample remains supported');
    my $h=$m->get('mb847_hist',$labels);
    is($h->{count},2,'finite recovery records only the two accepted observations');
    is($h->{sum},0,'histogram recovers to a finite sum');
    my $out=$m->render_prometheus;
    unlike($out,qr/\s(?:-?Inf|NaN|Infinity)(?:\s|$)/m,'no unbounded numeric value reaches Prometheus sample values');
    like($out,qr/mb847_hist_bucket\{channel="#overflow",le="\+Inf"\} 2/,'explicit final +Inf bucket remains present and counts accepted samples');
}
{
    my $m=metrics847();
    $m->declare('mb847_bucket_limits','histogram','finite bounds',buckets=>['1e999','-1e999','NaN',0,-1,.25,'2.5e-1',1]);
    $m->observe('mb847_bucket_limits',.5);my $out=$m->render_prometheus;
    like($out,qr/mb847_bucket_limits_bucket\{le="0[.]25"\} 0/,'valid scientific/decimal duplicate bucket is normalized');
    like($out,qr/mb847_bucket_limits_bucket\{le="1"\} 1/,'finite positive bucket remains ordered');
    unlike($out,qr/mb847_bucket_limits_bucket\{le="(?:Inf|-Inf|NaN)"/,'overflowing and non-finite bucket bounds are omitted');
    is(scalar(()=$out=~/^mb847_bucket_limits_bucket\{/mg),3,'two finite bounds and exactly one terminal +Inf bucket');
}
{
    my $m=metrics847();my $labels={channel=>'#new'};
    ok(!$m->set('mb847_gauge','1e999',$labels),'invalid first set is refused');
    is($m->get('mb847_gauge',$labels),undef,'invalid first set creates no sample');
    ok(!$m->add('mb847_counter','1e999',$labels),'invalid first increment is refused');
    is($m->get('mb847_counter',$labels),undef,'invalid first addition creates no sample');
    ok(!$m->observe('mb847_hist','1e999',$labels),'invalid first histogram sample is refused');
    is($m->get('mb847_hist',$labels),undef,'invalid first observation creates no histogram');
    ok($m->set('mb847_gauge',undef),'legacy undefined set still normalizes to zero');
    is($m->get('mb847_gauge'),0,'undefined set stores zero');
    ok($m->add('mb847_counter',undef),'legacy undefined delta still normalizes to zero');
    is($m->get('mb847_counter'),0,'undefined addition initializes zero');
    ok($m->set('mb847_gauge','-2.5e-2'),'finite scientific gauge is supported');
    is($m->get('mb847_gauge'),-.025,'finite negative scientific gauge retains its value');
    ok($m->observe('mb847_hist','3e-6'),'small Time::HiRes scientific sample remains supported');
    is($m->get('mb847_hist')->{count},1,'small scientific sample increments the histogram');
    my $disabled=Mediabot::Metrics->new(enabled=>0);
    ok(!$disabled->set('mediabot_up',5),'disabled metrics remain inert');
    ok(!$m->set('not_declared',2),'unknown metrics remain inert');
}
done_testing;
