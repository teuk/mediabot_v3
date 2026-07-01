#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib '.';
use Test::More;
use Encode qw(decode);

use Mediabot::ScriptActionRunner;

{
    package MB359::FakeIRC;

    sub new {
        return bless { messages => [] }, shift;
    }

    sub send_message {
        my ($self, @args) = @_;

        # Reproduce the production boundary: IO::Async/syswrite must receive
        # bytes, not a Perl scalar still flagged as wide characters.
        die "wide character reached IRC transport"
            if utf8::is_utf8($args[3]);

        push @{ $self->{messages} }, \@args;
        return 1;
    }

    sub messages {
        return $_[0]->{messages};
    }
}

my $irc = MB359::FakeIRC->new;

my $runner = Mediabot::ScriptActionRunner->new(
    bot             => { irc => $irc },
    max_text_length => 400,
);

my $context = {
    event   => 'public_command',
    channel => '#teuk',
    target  => '#teuk',
    nick    => 'Te[u]K',
    command => 'proll',
    args    => [ '2d6' ],
};

my $reply_text = "Te[u]K rolled 2d6 \x{2192} [5, 2] = 7";

my $reply = $runner->apply_actions(
    {
        ok       => 1,
        response => {
            ok      => 1,
            errors  => [],
            actions => [
                {
                    type   => 'reply',
                    target => '#teuk',
                    text   => $reply_text,
                },
            ],
        },
    },
    $context,
    apply     => 1,
    allow_irc => 1,
);

ok($reply->{applied_ok}, 'Unicode reply applies without a wide-character transport failure');
is(scalar @{ $irc->messages }, 1, 'one Unicode reply is sent');

my $reply_wire = $irc->messages->[0][3];
ok(!utf8::is_utf8($reply_wire), 'reply transport payload is an octet string');
is(decode('UTF-8', $reply_wire), $reply_text, 'reply UTF-8 payload decodes to the original text');

my $notice_text = "Result \x{2713}: caf\x{e9}";

my $notice = $runner->apply_actions(
    {
        ok       => 1,
        response => {
            ok      => 1,
            errors  => [],
            actions => [
                {
                    type   => 'notice',
                    target => 'Te[u]K',
                    text   => $notice_text,
                },
            ],
        },
    },
    $context,
    apply     => 1,
    allow_irc => 1,
);

ok($notice->{applied_ok}, 'Unicode notice applies without a wide-character transport failure');
is(scalar @{ $irc->messages }, 2, 'one Unicode notice is sent');

my $notice_wire = $irc->messages->[1][3];
ok(!utf8::is_utf8($notice_wire), 'notice transport payload is an octet string');
is(decode('UTF-8', $notice_wire), $notice_text, 'notice UTF-8 payload decodes to the original text');

is($irc->messages->[0][0], 'PRIVMSG', 'reply keeps the PRIVMSG command');
is($irc->messages->[1][0], 'NOTICE', 'notice keeps the NOTICE command');

my $source = do {
    local $/;
    open my $fh, '<', 'Mediabot/ScriptActionRunner.pm' or die $!;
    <$fh>;
};

like(
    $source,
    qr/mb359-B1: encode script-generated IRC text to UTF-8 bytes/,
    'ScriptActionRunner contains the MB359 UTF-8 wire marker',
);

done_testing();
