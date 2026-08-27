use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Encode qw(encode);
use Mediabot::VDM qw(format_vdm_line);

return sub {
    my ($assert) = @_;

    my $ok = format_vdm_line(id => 42, story => q{Aujourd'hui, petit test accentué. VDM});
    $assert->ok(defined($ok),
        'mb704-978: normal UTF-8 VDM remains renderable');
    $assert->ok(length(encode('UTF-8', $ok)) <= 400,
        'mb704-978: accepted VDM fits the normal one-message IRC byte budget');

    my $wide = ("é" x 210) . ' VDM';
    $assert->ok(length("[42] $wide") <= 350,
        'mb704-978: multibyte fixture remains below historical visible-char ceiling');
    $assert->ok(!defined(format_vdm_line(id => 42, story => $wide)),
        'mb704-978: formatter rejects a UTF-8 payload that would split on IRC wire');
};
