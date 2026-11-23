use strict;
use warnings;
use utf8;
use JSON::PP qw(decode_json encode_json);

binmode STDIN, ':raw';
binmode STDOUT, ':raw';

my $request = decode_json(do { local $/; <STDIN> });
my $text = join ' ', @{ $request->{data}{args} };
my @words = $text =~ /\S+/g;
my $reply = @words
    ? sprintf('Mots : %d | Caractères : %d', scalar(@words), length($text))
    : 'Usage : pmesure <texte>';

print encode_json({
    protocol => 'mediabot-script-v1',
    ok => JSON::PP::true,
    actions => [{ type => 'reply', text => $reply }],
});
