use strict;
use warnings;
use utf8;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Spec;
use Encode qw(encode);

BEGIN { unshift @INC, "$Bin/../.." }

use Mediabot::Hailo::BrainInfo qw(hailo_command);
use Mediabot::Context;

{
    package MB803::Brain;
    sub stats { (10, 20, 30, 40) }
}
{
    package MB803::Registry;
    sub new { bless { dir => $_[1], opens => [] }, $_[0] }
    sub brain_path_for {
        my ($self, $channel) = @_;
        my $file = lc($channel) eq '#other' ? 'other.brn' : 'io.brn';
        return File::Spec->catfile($self->{dir}, $file);
    }
    sub brain_for {
        my ($self, $channel) = @_;
        push @{ $self->{opens} }, $channel;
        return bless {}, 'MB803::Brain';
    }
}
{
    package MB803::Policy;
    sub operator_settings { { min_words => 3, max_words => 20, key_reply_rate => 95 } }
}
{
    package MB803::Bot;
    sub new {
        bless { hailo_registry => $_[1], hailo_policy => bless({}, 'MB803::Policy'),
                sent_public => [], sent_private => [] }, $_[0];
    }
    sub hailo_channel_policy { { master => 1, learn => 1, respond => 1, chatter => 0 } }
    sub get_hailo_channel_ratio { 0 }
    sub botPrivmsg { push @{ $_[0]{sent_public} }, [ $_[1], $_[2] ] }
    sub botNotice { push @{ $_[0]{sent_private} }, [ $_[1], $_[2] ] }
}
{
    package MB803::User;
    sub is_authenticated { 1 }
    sub has_level { $_[1] eq 'Master' }
}
{
    package MB803::Context;
    sub new { my ($class, %args) = @_; bless { public => [], private => [], %args }, $class }
    sub require_level {
        my ($self) = @_;
        return 1 if $self->{master};
        $self->reply_private('Access denied');
        return;
    }
    sub args { $_[0]{args} }
    sub channel { $_[0]{channel} }
    sub bot { $_[0]{bot} }
    sub reply { push @{ $_[0]{public} }, $_[1] }
    sub reply_private { push @{ $_[0]{private} }, $_[1] }
}

my $dir = tempdir(CLEANUP => 1);
for my $name ('io.brn', 'other.brn') {
    open my $fh, '>:raw', File::Spec->catfile($dir, $name) or die $!;
    print {$fh} 'brain';
    close $fh;
}
my $registry = MB803::Registry->new($dir);
my $bot = MB803::Bot->new($registry);
my $ctx = MB803::Context->new(bot => $bot, master => 1,
    channel => '#i/o', args => ['braininfo']);

ok(hailo_command($ctx), 'bare public braininfo uses the invoking channel');
is(scalar @{ $ctx->{public} }, 4, 'the complete report is published in the channel');
is(scalar @{ $ctx->{private} }, 0, 'same-channel report does not send private notices');
is_deeply($registry->{opens}, ['#i/o'], 'only the current brain was opened');
ok(!grep(length(encode('UTF-8', $_)) > 400, @{ $ctx->{public} }),
    'styled public lines remain within IRC byte budget');

$ctx->{args} = ['braininfo', '#i/o'];
$ctx->{public} = [];
ok(hailo_command($ctx), 'explicit current channel remains supported');
is(scalar @{ $ctx->{public} }, 4, 'explicit same-channel report is public');

$ctx->{args} = ['braininfo', '#I/O'];
$ctx->{public} = [];
ok(hailo_command($ctx), 'channel comparison ignores IRC case');
is(scalar @{ $ctx->{public} }, 4, 'IRC-equivalent current channel is public');

$ctx->{args} = ['braininfo', '#other'];
$ctx->{public} = [];
$ctx->{private} = [];
ok(hailo_command($ctx), 'explicit other channel remains supported');
is(scalar @{ $ctx->{public} }, 0, 'other channel information is not posted here');
is(scalar @{ $ctx->{private} }, 4, 'other channel report remains private');
like($ctx->{private}[0], qr/#other/, 'private report identifies its target');

$ctx->{channel} = undef;
$ctx->{args} = ['braininfo', '#i/o'];
$ctx->{public} = [];
$ctx->{private} = [];
ok(hailo_command($ctx), 'explicit private invocation still works');
is(scalar @{ $ctx->{public} }, 0, 'private invocation cannot publish');
is(scalar @{ $ctx->{private} }, 4, 'private invocation returns four notices');

$ctx->{args} = ['braininfo'];
$ctx->{private} = [];
my $opens = scalar @{ $registry->{opens} };
ok(!hailo_command($ctx), 'bare private braininfo has no implicit channel');
like($ctx->{private}[-1], qr/Syntax: hailo braininfo/, 'private syntax requests a channel');
is(scalar @{ $registry->{opens} }, $opens, 'invalid private invocation opens no brain');

$ctx->{channel} = '#i/o';
$ctx->{master} = 0;
$ctx->{public} = [];
$ctx->{private} = [];
ok(!hailo_command($ctx), 'unauthorized public request is denied');
is_deeply($ctx->{public}, [], 'authorization denial never reaches the channel');
is_deeply($ctx->{private}, ['Access denied'], 'denial remains private');

$ctx->{master} = 1;
$ctx->{args} = ['edits'];
$ctx->{public} = [];
$ctx->{private} = [];
ok(!hailo_command($ctx), 'bare edits does not inherit braininfo shortcut');
like($ctx->{private}[-1], qr/Syntax:/, 'edits still requires explicit channel');

my $real = Mediabot::Context->new(bot => $bot, nick => 'Operator',
    channel => '#i/o', command => 'hailo', args => ['braininfo']);
$real->{user} = bless {}, 'MB803::User';
$real->{_user_fetched} = 1;
ok(hailo_command($real), 'real Mediabot command context accepts bare braininfo');
is(scalar @{ $bot->{sent_public} }, 4, 'real reply helper publishes all report lines');
is($bot->{sent_public}[0][0], '#i/o', 'real reply helper targets the invoking channel');
is(scalar @{ $bot->{sent_private} }, 0, 'no unexpected private notices are emitted');

$real->{args} = ['braininfo', '#other'];
$bot->{sent_public} = [];
ok(hailo_command($real), 'real context retains explicit other-channel lookup');
is(scalar @{ $bot->{sent_public} }, 0, 'other brain is not disclosed to the channel');
is(scalar @{ $bot->{sent_private} }, 4, 'real context routes other-channel report privately');

done_testing;
