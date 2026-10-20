use strict;
use warnings;
use Mediabot::External ();

{ package MB866Conf; sub get { 'LOCAL_FIXTURE_ONLY' } }
{ package MB866Log; sub log { 1 } }
{
    package MB866HTTP;
    sub get {
        my ($self) = @_;
        ${$self->{calls}}++;
        return {
            success => 1, status => 200, reason => 'OK',
            content => $self->{body},
        };
    }
}
sub bot866 {
    return {
        conf => bless({}, 'MB866Conf'),
        logger => bless({}, 'MB866Log'),
    };
}
return sub {
    my ($assert) = @_;
    no warnings qw(redefine once);
    local *Mediabot::Helpers::noticeConsoleChan = sub { 1 };
    my $url = 'https://youtube.com/watch?v=AbCdEfGh123';

    for my $body ('[]', '[{}]', 'true', 'false',
                  '"text"', '42', 'null', 'not-json') {
        my $calls = 0;
        local *Mediabot::External::_make_http = sub {
            return bless {
                body => $body, calls => \$calls
            }, 'MB866HTTP';
        };
        my ($duration, $message);
        my $ok = eval {
            ($duration, $message) =
                Mediabot::External::YouTube::getYoutubeDetails(
                    bot866(), $url
                );
            1;
        };
        my $error = $@;
        $assert->ok($ok,
            "mb866: root $body is contained without exception: $error");
        $assert->ok(!defined($duration) && !defined($message),
            "mb866: root $body returns no fabricated metadata");
        $assert->is($calls, 1,
            "mb866: root $body performs only its metadata request");
    }

    my $calls = 0;
    local *Mediabot::External::_make_http = sub {
        return bless {
            calls => \$calls,
            body => '{"items":[{"snippet":{"title":"Local fixture"},'
                  . '"contentDetails":{"duration":"PT1M2S"},'
                  . '"statistics":{"viewCount":"10"}}]}',
        }, 'MB866HTTP';
    };
    my ($duration, $message) =
        Mediabot::External::YouTube::getYoutubeDetails(bot866(), $url);
    $assert->is($duration, 62,
        'mb866: valid object retains duration in seconds');
    $assert->like($message // '', qr/Local fixture/,
        'mb866: valid object retains the selected title');
    $assert->is($calls, 1,
        'mb866: valid metadata retains one HTTP request');
};
