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
use Mediabot::External::Facebook ();
use IPC::Open3;
use Symbol qw(gensym);

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

    for my $order (
        [qw(External::Facebook)],
        [qw(External::URL External::Facebook External)],
        [qw(External External::Facebook External::URL)],
    ) {
        my $code = "use Scalar::Util qw(refaddr);\n"
            . join('', map { "require Mediabot::$_;\n" } @$order);
        if (@$order == 1) {
            $code .= q{die 'eager URL load' if $INC{'Mediabot/External/URL.pm'};
                die 'eager AI load' if $INC{'Mediabot/External/Claude.pm'};
                die 'normalizer failed' unless
                    Mediabot::External::Facebook::_facebook_url('http://facebook.com/reel/AbC')
                        eq 'https://www.facebook.com/reel/AbC';
                package ColdFacebookLog; sub log {1} package main;
                die 'lazy title decode failed' unless
                    Mediabot::External::Facebook::_facebook_title_from_html(
                        {logger=>bless({},'ColdFacebookLog')}, '<title>A &amp; B</title>', 'cold')
                        eq 'A & B';};
        }
        $code .= q{require Mediabot::External;
            for my $name (@Mediabot::External::Facebook::EXPORT_OK) {
                my $owner = refaddr(Mediabot::External::Facebook->can($name));
                die 'legacy URL alias differs' unless $owner ==
                    refaddr(Mediabot::External::URL->can($name));
                die 'facade alias differs' unless $owner ==
                    refaddr(Mediabot::External->can($name));
            }
            print 'loaded';};
        my $err = gensym;
        my $pid = open3(undef, my $out, $err, $^X, '-I.', '-It/lib', '-we', $code);
        my $stdout = do { local $/; <$out> } // '';
        my $stderr = do { local $/; <$err> } // '';
        waitpid($pid, 0);
        $assert->ok($? == 0 && $stdout eq 'loaded' && $stderr eq '',
            'Facebook loads and retains aliases in order: ' . join('/', @$order));
    }

    {
        local *Mediabot::External::URL::_decode_html = sub { 'legacy decoded title' };
        $assert->is(Mediabot::External::Facebook::_facebook_title_from_html(
            {logger=>L857->new}, '<title>input</title>', 'override'),
            'legacy decoded title', 'Facebook still resolves the URL decoder at call time');
    }

    {
        my @hooks;
        my @out;
        local *Mediabot::External::URL::_facebook_url = sub {
            push @hooks, 'normalize'; return 'https://www.facebook.com/posts/AbC';
        };
        local *Mediabot::External::URL::_url_cache_identity = sub {
            push @hooks, 'cache'; return 'legacy cache key';
        };
        local *Mediabot::External::URL::_decode_http_content_utf8 = sub {
            push @hooks, 'http decode'; return '<title>Facebook</title>';
        };
        local *Mediabot::External::URL::_facebook_title_from_html = sub {
            push @hooks, 'title ' . $_[2]; return undef;
        };
        local *Mediabot::External::URL::_fetch_url_chromium_dumpdom = sub {
            push @hooks, 'browser';
            return '<meta property="og:description" content="input">';
        };
        local *Mediabot::External::URL::_facebook_fallback_title_from_url = sub {
            push @hooks, 'fallback'; return 'Émission 🦉';
        };
        local *Mediabot::External::URL::_decode_html = sub {
            push @hooks, 'html decode'; return 'Legacy details';
        };
        local *Mediabot::External::_make_http = sub {
            push @hooks, 'http'; return H857->new('<title>input</title>');
        };
        local *Mediabot::Helpers::botPrivmsg = sub { push @out, [$_[1], $_[2]]; 1 };
        my $self = {logger=>L857->new, conf=>C857->new};
        my $ret = Mediabot::External::_handle_facebook(
            $self, undef, 'First', '#test', 'legacy input');
        my $replay = Mediabot::External::URL::_handle_facebook(
            $self, undef, 'Second', '#i/o', 'legacy replay');
        $assert->ok($ret && $replay && @out == 2
            && join('|', @hooks) eq 'normalize|cache|http|http decode|title HTTP|browser|title Chromium|fallback|html decode|normalize|cache'
            && $out[0][0] eq '#test' && $out[1][0] eq '#i/o'
            && _strip_irc_857($out[0][1]) eq '(First) [Facebook] Émission 🦉 - Legacy details'
            && _strip_irc_857($out[1][1]) eq '(Second) [Facebook] Émission 🦉 - Legacy details'
            && utf8::is_utf8($out[0][1]) && utf8::is_utf8($out[1][1])
            && exists $self->{_facebook_cache}{'legacy cache key'},
            'legacy normalization, parser, decoder, browser, fallback and cache hooks survive facade delivery and replay');
    }

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
