use strict;
use warnings;
use Test::More;
use Mediabot::External::YouTube ();

my $id = 'AbCdEfGh123';
my $other = 'ZyXwVuTs987';
my $select = \&Mediabot::External::YouTube::_is_youtube_url;
for my $country (qw(com fr de co.uk co.jp be)) {
    for my $subdomain ('', 'www.', 'm.', 'music.') {
        is($select->("https://${subdomain}youtube.$country/watch?v=$id"), $id,
            "watch host $subdomain/$country retains its supported identity");
    }
}
for my $family (qw(shorts live)) {
    for my $country (qw(com fr de co.uk co.jp)) {
        for my $subdomain ('', 'www.', 'm.') {
            is($select->("https://${subdomain}youtube.$country/$family/$id?feature=share#part"), $id,
                "$family host $subdomain/$country retains its supported identity");
        }
    }
}
for my $host (qw(youtube.com www.youtube.com youtube-nocookie.com www.youtube-nocookie.com)) {
    is($select->("https://$host/embed/$id?start=10#part"), $id, 'supported embed host retains its identity');
}
for my $url (
    "http://youtube.com/watch?v=$id",
    "HTTPS://WWW.YOUTUBE.COM/watch?feature=share&v=$id&t=10",
    "https://music.youtube.com/watch?list=List&v=$id#part",
    "https://youtube.com/watch?unrelated=&v=$id&feature=share",
    "https://youtube.com/watch?v=$id&next=https://example.test/?v=$other",
    "https://youtube.com/watch?v=$id&next=https%3A%2F%2Fexample.test%2F%3Fv%3D$other",
    "https://youtube.com/watch?v=$id#part&v=$other",
    "https://youtube.com/watch?v=$id#https://youtube.com/watch?v=$other",
    "https://youtube.com/watch?v=$id&adv=$other",
    "https://youtu.be/$id?t=10#part&v=$other",
    "https://youtu.be/$id/",
    "https://youtube.com/shorts/$id/?feature=share",
    "https://youtube.com/live/$id#part",
    "https://youtube-nocookie.com/embed/$id/",
) {
    is($select->($url), $id, 'only the selected outer video supplies the ID');
}
for my $url (
    "https://youtube.com/watch?v=$id&v=$other",
    "https://youtube.com/watch?v=$id&v=$id",
    "https://youtube.com/watch?v=&v=$id",
    "https://youtube.com/watch?other=1#v=$id",
    "https://youtube.com/watch?next=https://example.test/?v=$id",
    "https://youtube.com/watch?adv=$id",
    "https://youtube.com/watch-later?v=$id",
    "https://youtube.com/watch/extra?v=$id",
    "https://youtube.com/watch?v=${id}EXTRA",
    "https://youtube.com/watch?v=$id/extra",
    "https://youtu.be/${id}EXTRA",
    "https://youtube.com/shorts/${id}EXTRA?feature=share",
    "https://youtube.com/live/${id}EXTRA",
    "https://youtube.com/embed/${id}EXTRA",
    "https://youtube-nocookie.com/embed/${id}EXTRA",
    "https://youtu.be/$id/extra",
    "https://youtube.com/shorts/$id/extra",
    "https://example.test/?u=https://youtube.com/watch?v=$id",
    "https://notyoutube.com/watch?v=$id",
    "https://youtube.com.example.test/watch?v=$id",
    "https://youtube.com\@example.test/watch?v=$id",
    "https://notyoutu.be/$id",
    "https://youtu.be.example.test/$id",
    "https://example.test/shorts/$id",
    "https://youtube.com/watch?v=too_short",
    "https://youtube.com/watch?v=$id\n",
    "https://youtube.com/watch?v=$id\x00",
    "text https://youtube.com/watch?v=$id",
    $id, '', undef, [], {},
) {
    my ($value, $ok, @warnings);
    {local $SIG{__WARN__}=sub {push @warnings, @_}; $ok=eval {$value=$select->($url);1}}
    ok($ok && !defined($value) && !@warnings, 'ambiguous, incomplete or non-URL input selects no video without warnings');
}
done_testing;
