use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::Spark::Observer;
use Mediabot::Spark::Portal;
use Mediabot::Spark::Mosaic;

my @cases = (
    ["\x0304,12magic", 'magic'],
    ["\x03magic", 'magic'],
    ["\x030412magic", '12magic'],
);
for my $digits ('١٢', '１２', '१२', '𝟙𝟚') {
    push @cases, ["\x03${digits}magic", "${digits}magic"],
                 ["\x0304${digits}magic", "${digits}magic"],
                 ["\x0304,12${digits}magic", "${digits}magic"];
}
for my $case (@cases) {
    my ($input, $expected) = @$case;
    my $observer = Mediabot::Spark::Observer->new(clock => sub { 1000 });
    $observer->observe_public_line(channel => '#test', nick => 'alice', message => $input);
    is_deeply($observer->context_lines('#test'), ["alice: $expected"], 'observer preserves visible digits');
    for my $class ('Mediabot::Spark::Portal', 'Mediabot::Spark::Mosaic') {
        my $collector = $class->new(clock => sub { 1000 });
        my %event = (channel => '#test', generation => 1, target => 2);
        $collector->begin(%event);
        my $message = $class =~ /Mosaic/ ? "+$input" : $input;
        is($collector->collect(%event, nick => 'alice', message => $message)->{action}, 'collect', "$class accepts contribution");
        is_deeply($collector->contributions(%event), [$expected], "$class preserves visible digits");
    }
}
# A comma followed by non-ASCII digits is visible text, not a background colour.
my $observer = Mediabot::Spark::Observer->new(clock => sub { 1000 });
$observer->observe_public_line(channel => '#test', nick => 'alice', message => "\x0304,١٢magic");
is_deeply($observer->context_lines('#test'), ['alice: ,١٢magic'], 'non-ASCII background suffix remains literal');
my $portal = Mediabot::Spark::Portal->new(clock => sub { 1000 });
$portal->begin(channel => '#test', generation => 1);
$portal->collect(channel => '#test', generation => 1, nick => 'alice', message => "\x0304,١٢magic");
is_deeply($portal->contributions(channel => '#test', generation => 1), [',١٢magic'], 'Portal retains literal comma and digits');
my $mosaic = Mediabot::Spark::Mosaic->new(clock => sub { 1000 });
$mosaic->begin(channel => '#test', generation => 1, target => 2);
is($mosaic->collect(channel => '#test', generation => 1, nick => 'alice', message => "+\x0304,١٢magic")->{reason}, 'invalid_word', 'Mosaic validates the actual visible comma instead of silently deleting it');
done_testing;
