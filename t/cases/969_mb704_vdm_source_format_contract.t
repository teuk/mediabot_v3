use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::VDM qw(
    vdm_feed_url
    vdm_repeat_window_seconds
    vdm_item_id
    format_vdm_line
);

return sub {
    my ($assert) = @_;

    $assert->is(vdm_feed_url(), 'https://www.viedemerde.fr/feeds/articles',
        'mb704-969: VDM source contract uses the current official article feed');
    $assert->is(vdm_repeat_window_seconds(), 120,
        'mb704-969: immediate anti-repeat contract remains 120 seconds');

    $assert->is(vdm_item_id({ id => '513869' }), '513869',
        'mb704-969: explicit numeric id is accepted');
    $assert->is(vdm_item_id({ url => 'https://www.viedemerde.fr/article/bien-tente-p-tit_513869.html' }), '513869',
        'mb704-969: current VDM article URL yields numeric story id');
    $assert->is(vdm_item_id({ guid => 'https://example.invalid/article/12345.html' }), '12345',
        'mb704-969: generic numeric article URL id is supported');
    $assert->ok(!defined(vdm_item_id({ url => 'https://example.invalid/no-id' })),
        'mb704-969: missing item id fails closed');

    my $story = "Aujourd'hui, le sort a choisi le mauvais chaudron. VDM";
    my $line = format_vdm_line(id => 513869, story => $story);

    $assert->ok(defined($line),
        'mb704-969: valid source story is renderable');
    $assert->like($line, qr/^\x02\x0301,15\[513869\]\x0f /,
        'mb704-969: id is bold with historical foreground/background colors');
    $assert->like($line, qr/\x0300,14\Q$story\E\x0f\z/,
        'mb704-969: story uses historical quote colors and final reset');
    $assert->unlike($line, qr/[\r\n]/,
        'mb704-969: rendered VDM is exactly one IRC line');

    $assert->ok(!defined(format_vdm_line(id => 'x', story => $story)),
        'mb704-969: non-numeric story id is rejected');
    $assert->ok(!defined(format_vdm_line(id => 42, story => "Aujourd'hui\nVDM")),
        'mb704-969: multiline source payload is rejected');
    $assert->ok(!defined(format_vdm_line(id => 42, story => "Aujourd'hui \x03spoof VDM")),
        'mb704-969: source IRC-control injection is rejected');
    $assert->ok(!defined(format_vdm_line(id => 42, story => "Aujourd'hui, incomplet.")),
        'mb704-969: formatter never invents a missing VDM closing marker');

    my $too_long = ('x' x 345) . ' VDM';
    $assert->ok(!defined(format_vdm_line(id => 123456, story => $too_long)),
        'mb704-969: over-budget output is rejected rather than rewritten');
};
