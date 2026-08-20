# t/cases/856_mb672_url_cache_chanset_gate.t
use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::External ();
use Mediabot::External::URL ();

{
    package L856;
    sub new { bless {}, shift }
    sub log { 1 }
}

return sub {
    my ($assert) = @_;
    no warnings 'redefine';
    no warnings 'once';

    my $enabled = 0;
    my $handled = 0;

    local *Mediabot::External::_chanset_ok = sub {
        my ($self, $channel, $name) = @_;
        return $enabled if $name eq 'AppleMusic';
        return 0;
    };

    local *Mediabot::External::URL::_handle_applemusic = sub {
        $handled++;
        return 1;
    };

    my $self = bless { logger => L856->new }, 'Bot856';
    my $url = 'https://music.apple.com/se/album/example/123?i=456';

    my $off = Mediabot::External::URL::displayUrlTitle(
        $self, undef, 'nick', '#c', $url
    );

    $assert->ok(!defined($off),
        'mb672-856: disabled AppleMusic chanset produces no handler result');
    $assert->is($handled, 0,
        'mb672-856: disabled AppleMusic chanset does not dispatch handler');
    $assert->is(scalar(keys %{ $self->{_url_display_cache} // {} }), 0,
        'mb672-856: disabled chanset does not burn URL in anti-repeat cache');

    $enabled = 1;
    my $on = Mediabot::External::URL::displayUrlTitle(
        $self, undef, 'nick', '#c', $url
    );

    $assert->is($on, 1,
        'mb672-856: same URL works immediately after enabling AppleMusic');
    $assert->is($handled, 1,
        'mb672-856: enabled AppleMusic dispatches exactly once');
    $assert->is(scalar(keys %{ $self->{_url_display_cache} // {} }), 1,
        'mb672-856: accepted URL is armed in anti-repeat cache');

    my $repeat = Mediabot::External::URL::displayUrlTitle(
        $self, undef, 'nick', '#c', $url
    );

    $assert->ok(!defined($repeat),
        'mb672-856: immediate repeat in same channel remains suppressed');
    $assert->is($handled, 1,
        'mb672-856: normal same-channel anti-repeat behavior is preserved');

    my $other_channel = Mediabot::External::URL::displayUrlTitle(
        $self, undef, 'nick', '#d', $url
    );

    $assert->is($other_channel, 1,
        'mb672-856: same URL in another channel remains independently allowed');
    $assert->is($handled, 2,
        'mb672-856: anti-repeat cache remains channel-scoped');
};
