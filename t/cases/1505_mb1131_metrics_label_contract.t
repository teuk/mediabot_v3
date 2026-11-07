use strict;
use warnings;
use utf8;
use Test::More;
use Storable qw(dclone);
use Mediabot::Metrics;
{
    package MB1131HostileLabel;
    use overload '""' => sub { die 'label coercion' },
                 'bool' => sub { die 'label truthiness' }, fallback => 1;
}
for my $labels ([], 'channel', 0, {channel => []}, {channel => {}},
                {channel => bless({}, 'MB1131HostileLabel')},
                bless({}, 'MB1131HostileLabel'),
                {'bad-label' => 'x'}, {"bad\nname" => 'x'}, {'' => 'x'}) {
    my $m = Mediabot::Metrics->new(enabled => 1);
    $m->declare('label_gauge', 'gauge', 'gauge');
    $m->declare('label_hist', 'histogram', 'histogram');
    $m->set('label_gauge', 7);
    $m->observe('label_hist', .1);
    my $before = dclone($m->{metrics});
    my (@warnings, @results);
    {
        local $SIG{__WARN__} = sub { push @warnings, shift };
        ok(eval {
            @results = ($m->set('label_gauge', 42, $labels),
                        $m->add('label_gauge', 1, $labels),
                        $m->inc('label_gauge', $labels),
                        $m->observe('label_hist', .2, $labels),
                        $m->get('label_gauge', $labels));
            1;
        }, 'malformed labels do not throw or invoke overloads');
    }
    ok(!(grep { defined $_ } @results), 'malformed label set is rejected by every accessor');
    is_deeply($m->{metrics}, $before, 'rejection leaves every existing series unchanged');
    is_deeply(\@warnings, [], 'malformed labels produce no warnings');
}
{
    my $m = Mediabot::Metrics->new(enabled => 1);
    $m->declare('label_hist', 'histogram', 'histogram');
    ok(!defined $m->observe('label_hist', .1, {le => 'custom'}), 'histogram rejects reserved bucket label');
    is_deeply($m->{metrics}{label_hist}{values}, {}, 'reserved label creates no invalid histogram');
    my $labels = {channel => "#café\\\"\n", empty => undef, zero => 0};
    ok($m->observe('label_hist', .2, $labels), 'valid Unicode and escaped labels remain accepted');
    is($m->get('label_hist', $labels)->{count}, 1, 'valid labels retain their identity');
    my $output = $m->render_prometheus;
    like($output, qr/label_hist_count\{channel="#café\\\\\\"\\n",empty="",zero="0"\} 1/, 'export escapes values exactly once');
    $m->declare('label_gauge', 'gauge', 'gauge');
    ok($m->set('label_gauge', 5, {}), 'empty hash remains an unlabelled series');
    is($m->get('label_gauge'), 5, 'omitted labels access the same unlabelled series');
    ok($m->set('label_gauge', 2, {le => 'allowed'}), 'le remains valid on ordinary gauges');
}
done_testing;
