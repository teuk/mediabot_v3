use strict;
use warnings;
use utf8;
use lib '.', 't/lib';
use Test::More;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode);
use Mediabot::Hailo::Normalizer qw(
    hailo_placeholder_for_nick normalize_hailo_input rehydrate_hailo_output
);

# Golden tokens recorded on the intact MB850 base. Existing byte-sized
# nick/channel mappings must keep working with already learned placeholders.
my @legacy = (
    ['#Salon', 'B[o]b', ['zzhailonick29zz', 'zzhailonick29zz']],
    ['#CAFÉ', 'Élodie', ['zzhailonick14zz', 'zzhailonick29zz']],
    ['#salon', encode('UTF-8', 'Café'), ['zzhailonick10zz', 'zzhailonick12zz']],
);
for my $case (@legacy) {
    for my $flag (0,1) {
        my ($channel, $nick, $expected) = @$case;
        if ($flag) {utf8::upgrade($channel); utf8::upgrade($nick)}
        else {utf8::downgrade($channel, 1); utf8::downgrade($nick, 1)}
        is(hailo_placeholder_for_nick(channel => $channel, nick => $nick), $expected->[$flag],
            "legacy nick/channel flag=$flag retains its original learned token");
    }
}
for my $case (['#東京', 'B[o]b'], ['#salon', 'Łukasz'], ['#café-🧭', '東京太郎さん']) {
    my ($channel, $nick) = @$case;
    my ($token, $warning) = (undef, ''); my $ok;
    {local $SIG{__WARN__} = sub {$warning .= $_[0]};
     $ok = eval {$token = hailo_placeholder_for_nick(channel => $channel, nick => $nick); 1}}
    ok($ok, 'wide nick/channel can select a neutral placeholder');
    is($warning, '', 'wide placeholder hashing emits no warning');
    like($token // '', qr/\Azzhailonick\d{2}zz\z/, 'wide identity retains bounded opaque token shape');
    my $folded_channel = lc $channel; $folded_channel =~ tr/[]\\^/{}|~/;
    my $folded_nick = lc $nick; $folded_nick =~ tr/[]\\^/{}|~/;
    my $digest = sha256_hex(encode('UTF-8', "$folded_channel\0$folded_nick"));
    my $expected = sprintf('zzhailonick%02dzz', hex(substr($digest, 0, 8)) % 32);
    is($token, $expected, 'wide nick/channel uses explicit UTF-8 with existing bucket count');
    my $normal;
    $ok = eval {$normal = normalize_hailo_input(channel => $channel, speaker => 'A', bot_nick => 'Bot',
        nicks => [$nick, 'A', 'Bot'], text => "Bot: bonjour $nick"); 1};
    ok($ok && $normal->{ok}, 'real normalizer accepts a turn with a wide identity');
    is($normal ? $normal->{text} : '', "bonjour $expected", 'learnable text contains a neutral token rather than raw nick');
    is($normal ? $normal->{target_nick} : '', $nick, 'raw target stays in ephemeral turn metadata');
    my $out;
    $ok = eval {$out = rehydrate_hailo_output(channel => $channel, speaker => 'A', bot_nick => 'Bot',
        nicks => [$nick, 'A', 'Bot'], bucket_nicks => $normal ? $normal->{bucket_nicks} : {},
        text => "bonjour $expected"); 1};
    ok($ok && $out->{ok}, 'real rehydration accepts a wide identity turn');
    is($out ? $out->{line} : '', "bonjour $nick", 'placeholder restores exact currently visible international nick');
    my $command;
    $ok = eval {$command = normalize_hailo_input(channel => $channel, speaker => 'A', bot_nick => 'Bot',
        nicks => [$nick], text => "!dtc $nick"); 1};
    ok($ok && $command->{is_command}, 'wide identities retain incoming command classification');
    my $blocked;
    $ok = eval {$blocked = rehydrate_hailo_output(channel => $channel, speaker => 'A', bot_nick => 'Bot',
        nicks => [$nick], text => '!dtc'); 1};
    ok($ok, 'output command check does not throw while rebuilding wide nick buckets');
    is($blocked ? $blocked->{reason} : '', 'command_output', 'wide identities cannot bypass output command rejection');
}
is(hailo_placeholder_for_nick(channel => 'private', nick => 'Nick'), undef,
    'private target remains invalid for learned nick placeholders');
is(normalize_hailo_input(channel => '#salon', speaker => 'A', text => "bad\0input")->{reason},
    'invalid_input', 'NUL-bearing input remains invalid');
done_testing;
