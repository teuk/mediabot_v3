# t/cases/857_mb672_facebook_reel_fast_fallback.t
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
    package L857;
    sub new { bless {}, shift }
    sub log { 1 }

    package H857;
    sub new { bless { body => $_[1] }, $_[0] }
    sub get {
        my ($self) = @_;
        return {
            success => 1,
            status  => 200,
            reason  => 'OK',
            content => $self->{body},
            headers => { 'content-type' => 'text/html; charset=utf-8' },
        };
    }

    package C857;
    sub new { bless {}, shift }
    sub get { undef }
}

sub _strip_irc_857 {
    my ($s) = @_;
    $s //= '';
    $s =~ s/\x03\d{0,2}(?:,\d{1,2})?|\x0f|\x02//g;
    return $s;
}

return sub {
    my ($assert) = @_;
    no warnings 'redefine';
    no warnings 'once';

    my @sent;
    local *Mediabot::Helpers::botPrivmsg = sub {
        my ($self, $channel, $line) = @_;
        push @sent, $line;
        return 1;
    };

    # Reel shell: HTTP only exposes the generic Facebook shell. Chromium must
    # not run; the existing deterministic Reel fallback is returned directly.
    {
        my $chromium_calls = 0;

        local *Mediabot::External::_make_http = sub {
            return H857->new(
                '<html><head><title>Facebook</title></head><body></body></html>'
            );
        };

        local *Mediabot::External::URL::_fetch_url_chromium_dumpdom = sub {
            $chromium_calls++;
            return q{<meta property="og:title" content="Unexpected rendered Reel title"/>};
        };

        @sent = ();
        my $self = {
            logger => L857->new,
            conf => C857->new,
            _facebook_cache => {},
        };

        my $rc = Mediabot::External::URL::_handle_facebook(
            $self, undef, 'nick', '#c',
            'https://www.facebook.com/reel/1672309937302951'
        );

        $assert->is(
            $rc, 1,
            'mb672-857: Reel shell still returns a handled result'
        );
        $assert->is(
            $chromium_calls, 0,
            'mb672-857: Reel shell skips known-dead Chromium fallback'
        );
        $assert->like(
            _strip_irc_857($sent[0] // ''),
            qr/\[Facebook\].*Facebook reel/,
            'mb672-857: Reel shell keeps badge and deterministic fallback'
        );
    }

    # No regression: non-Reel shells retain the historical Chromium fallback.
    {
        my $chromium_calls = 0;

        local *Mediabot::External::_make_http = sub {
            return H857->new(
                '<html><head><title>Facebook</title></head><body></body></html>'
            );
        };

        local *Mediabot::External::URL::_fetch_url_chromium_dumpdom = sub {
            $chromium_calls++;
            return q{<html><head><meta property="og:title" content="Rendered Facebook post"/></head></html>};
        };

        @sent = ();
        my $self = {
            logger => L857->new,
            conf => C857->new,
            _facebook_cache => {},
        };

        my $rc = Mediabot::External::URL::_handle_facebook(
            $self, undef, 'nick', '#c',
            'https://www.facebook.com/example/posts/123'
        );

        $assert->is(
            $rc, 1,
            'mb672-857: non-Reel shell remains handled'
        );
        $assert->is(
            $chromium_calls, 1,
            'mb672-857: non-Reel shell retains Chromium fallback'
        );
        $assert->like(
            _strip_irc_857($sent[0] // ''),
            qr/\[Facebook\].*Rendered Facebook post/,
            'mb672-857: rendered non-Reel metadata is preserved'
        );
    }
};
