# MB720-C — MegaHAL-compatible Hailo normalization and nick placeholders.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Hailo::Normalizer qw(
    normalize_hailo_input
    rehydrate_hailo_output
    hailo_placeholder_for_nick
);

return sub {
    my ($assert) = @_;

    my $normalized = normalize_hailo_input(
        channel          => '#Salon',
        speaker          => 'Alice',
        bot_nick         => 'Media[bot]',
        nicks            => [ 'Alice', 'B[o]b', 'Media[bot]' ],
        command_prefixes => [ '!', '.' ],
        text             => "\x0304[12:34] <Alice> Media[bot]: salut B[o]b  ",
    );
    $assert->ok($normalized->{ok},
        'formatted copied line is accepted after bounded normalization');
    $assert->unlike($normalized->{text}, qr/12:34|Alice|Media\[bot\]|B\[o\]b/i,
        'timestamps, paste prefixes and raw visible nicks stay out of Hailo');
    $assert->like($normalized->{text}, qr/^salut zzhailonick\d{2}zz$/,
        'other visible nick becomes a neutral durable bucket placeholder');
    $assert->is($normalized->{target_nick}, 'B[o]b',
        'first mentioned peer is retained only in ephemeral turn metadata');

    my $speaker_line = normalize_hailo_input(
        channel  => '#Salon',
        speaker  => 'Alice',
        bot_nick => 'Media[bot]',
        nicks    => [ 'Alice', 'Media[bot]' ],
        text     => 'Media[bot], Alice pense que Media[bot] a raison',
    );
    $assert->like($speaker_line->{text}, qr/zzhailospeakerzz/i,
        'interlocutor has a dedicated reversible placeholder');
    $assert->like($speaker_line->{text}, qr/zzhailoselfzz/i,
        'bot identity has a dedicated reversible placeholder');

    my $output = rehydrate_hailo_output(
        channel          => '#Salon',
        speaker          => 'Alice',
        bot_nick         => 'Media[bot]',
        nicks            => [ 'Alice', 'B[o]b', 'Media[bot]' ],
        bucket_nicks     => $normalized->{bucket_nicks},
        command_prefixes => [ '!', '.' ],
        text             => $normalized->{text},
    );
    $assert->ok($output->{ok},
        'safe Hailo candidate is rehydrated');
    $assert->is($output->{line}, 'salut B[o]b',
        'placeholder restores a currently visible nick with exact IRC casing');

    my $self_output = rehydrate_hailo_output(
        channel  => '#Salon',
        speaker  => 'Alice',
        bot_nick => 'Media[bot]',
        nicks    => [ 'Alice', 'Media[bot]' ],
        text     => 'zzhailoselfzz a raison, zzhailospeakerzz',
    );
    $assert->is($self_output->{line}, 'Alice a raison, Alice',
        'historic MegaHAL nick-switch behaviour targets the interlocutor');

    my $command = normalize_hailo_input(
        channel          => '#Salon',
        speaker          => 'Alice',
        bot_nick         => 'Media[bot]',
        command_prefixes => [ '!', '.' ],
        text             => '!kick B[o]b',
    );
    $assert->ok($command->{is_command},
        'incoming command prefixes are classified before learning');

    my $command_output = rehydrate_hailo_output(
        channel          => '#Salon',
        speaker          => 'Alice',
        bot_nick         => 'Media[bot]',
        command_prefixes => [ '!', '.' ],
        text             => '.chanset #Salon -Hailo',
    );
    $assert->is($command_output->{reason}, 'command_output',
        'Hailo can never emit a learned command');

    my $bad = normalize_hailo_input(
        channel => '#Salon', speaker => 'Alice', text => "hello\0world",
    );
    $assert->is($bad->{reason}, 'invalid_input',
        'NUL-bearing input is rejected');

    my $token = hailo_placeholder_for_nick(channel => '#Salon', nick => 'B[o]b');
    $assert->like($token, qr/^zzhailonick\d{2}zz$/,
        'bucket token is opaque and contains no raw nickname');
};
