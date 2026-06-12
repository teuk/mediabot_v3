use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
my $in = do { local $/; <STDIN> };
my $payload = decode_json($in);
print encode_json({
    actions => [
        {
            type   => 'reply',
            target => $payload->{data}{channel},
            text   => 'ok:' . $payload->{data}{command},
        }
    ]
});
