use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use Mediabot::Spark::Generator qw(build_spark_request);
use Mediabot::Spark::Identity qw(is_known_bot_nick);
use Mediabot::Spark::Observer;

return sub {
    my ($assert) = @_;

    $assert->ok(is_known_bot_nick(
        nick => 'RelayBot', bot_nick => 'Mediabot',
        configured_bot_nicks => ' feedbot, RelayBot ',
    ), 'mb710-1004: configured bot identity is case-insensitive and trimmed');
    $assert->ok(is_known_bot_nick(
        nick => 'MEDIABOT', bot_nick => 'Mediabot', configured_bot_nicks => '',
    ), 'mb710-1004: the live bot nick is always automation');
    $assert->ok(!is_known_bot_nick(
        nick => 'Alice', bot_nick => 'Mediabot',
        configured_bot_nicks => 'feedbot,RelayBot',
    ), 'mb710-1004: an unlisted human stays human');

    my $now = 10_000;
    my $observer = Mediabot::Spark::Observer->new(clock => sub { $now });
    my $initial = $observer->observe_public_line(
        channel => '#room', nick => 'Alice', bot_nick => 'Mediabot',
        message => 'm vdm', command_char => '!', initial_trigger_enabled => 1,
    );
    $assert->is($initial->{reason}, 'initial_trigger',
        'mb710-1004: enabled one-letter commands stay out of Spark context');
    my $direct = $observer->observe_public_line(
        channel => '#room', nick => 'Alice', bot_nick => 'Mediabot',
        message => 'Mediabot:status', command_char => '!',
    );
    $assert->is($direct->{reason}, 'bot_trigger',
        'mb710-1004: direct bot triggers stay out of Spark context');

    my @context = map { sprintf('Alice: line-%02d', $_) } 1 .. 12;
    my $request = build_spark_request(
        kind => 'fork', language => 'en', context => \@context,
    );
    my $material = $request->{messages}[0]{content};
    $assert->unlike($material, qr/line-(?:01|02|03|04)\b/,
        'mb710-1004: the oldest four lines are dropped at the provider bound');
    $assert->like($material, qr/line-05.*line-12/s,
        'mb710-1004: the newest eight lines survive in chronological order');
};
