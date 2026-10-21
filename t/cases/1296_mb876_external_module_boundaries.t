use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode);
use IPC::Open3;
use Symbol qw(gensym);
use Scalar::Util qw(refaddr);
use Mediabot::External ();
use Mediabot::External::YouTube ();
use Mediabot::External::Weather ();
use Mediabot::External::Fortnite ();
use Mediabot::External::URLCodec ();

# A fresh interpreter proves that loading an owner does not depend on a
# particular earlier import order or pull an unrelated feature back in.
my @cold = (
    ['codec', q{use Mediabot::External::URLCodec qw(_uri_escape_bytes);
        die 'unexpected video dependency' if $INC{'Mediabot/External/YouTube.pm'};
        die 'unexpected weather dependency' if $INC{'Mediabot/External/Weather.pm'};
        die 'unexpected game dependency' if $INC{'Mediabot/External/Fortnite.pm'};
        die 'missing import' unless _uri_escape_bytes('New York') eq 'New%20York';}],
    ['weather', q{use Mediabot::External::Weather qw(displayWeather_ctx);
        die 'unexpected video dependency' if $INC{'Mediabot/External/YouTube.pm'};
        die 'unexpected game dependency' if $INC{'Mediabot/External/Fortnite.pm'};
        die 'missing import' unless defined &displayWeather_ctx;}],
    ['Fortnite', q{use Mediabot::External::Fortnite qw(getFortniteId fortniteStats_ctx);
        die 'unexpected video dependency' if $INC{'Mediabot/External/YouTube.pm'};
        die 'unexpected weather dependency' if $INC{'Mediabot/External/Weather.pm'};
        die 'missing imports' unless defined &getFortniteId && defined &fortniteStats_ctx;}],
    ['legacy YouTube imports', q{use Mediabot::External::YouTube qw(displayWeather_ctx getFortniteId fortniteStats_ctx);
        die 'legacy imports lost' unless defined &displayWeather_ctx && defined &getFortniteId && defined &fortniteStats_ctx;}],
);
for my $order (
    [qw(Weather Fortnite YouTube)], [qw(Fortnite YouTube Weather)], [qw(YouTube Weather Fortnite)],
) {
    my $load = join '', map { "require Mediabot::External::$_;\n" } @$order;
    push @cold, [join('/', @$order), $load . q{require Mediabot::External;
        die 'facade weather missing' unless defined &Mediabot::External::displayWeather_ctx;
        die 'facade game missing' unless defined &Mediabot::External::fortniteStats_ctx;}];
}
for my $case (@cold) {
    my ($label, $code) = @$case;
    my $err = gensym;
    my $pid = open3(undef, my $out, $err, $^X, '-I.', '-It/lib', '-we', $code . q{print 'loaded';});
    my $stdout = do {local $/; <$out>} // '';
    my $stderr = do {local $/; <$err>} // '';
    waitpid($pid, 0);
    is($?, 0, "$label: cold load exits successfully");
    is($stdout, 'loaded', "$label: interpreter reaches the complete import check");
    is($stderr, '', "$label: no circular-load or redefinition diagnostics");
}

for my $row (
    ['Weather', 'displayWeather_ctx'],
    ['Fortnite', 'getFortniteId'], ['Fortnite', 'fortniteStats_ctx'],
) {
    my ($owner, $name) = @$row;
    no strict 'refs';
    my $implementation = \&{"Mediabot::External::${owner}::$name"};
    is(refaddr(\&{"Mediabot::External::$name"}), refaddr($implementation), "$name: facade uses its owner directly");
    is(refaddr(\&{"Mediabot::External::YouTube::$name"}), refaddr($implementation), "$name: legacy entry uses the same implementation");
}

for my $row (
    [undef, ''], ['', ''], ['Paris', 'Paris'], ['New York', 'New%20York'],
    ['Genève', 'Gen%C3%A8ve'], [encode('UTF-8', 'Genève'), 'Gen%C3%A8ve'],
    ['💧', '%F0%9F%92%A7'], [encode('UTF-8', '💧'), '%F0%9F%92%A7'],
    ['-33.8688,151.2093', '-33.8688%2C151.2093'], ['a/b?x=1&y=2', 'a%2Fb%3Fx%3D1%26y%3D2'],
) {
    for my $codec (\&Mediabot::External::URLCodec::_uri_escape_bytes,
        \&Mediabot::External::YouTube::_uri_escape_bytes, \&Mediabot::External::Weather::_uri_escape_bytes) {
        is($codec->($row->[0]), $row->[1], 'shared codec and its existing callers retain exact byte escaping');
    }
}
done_testing;
