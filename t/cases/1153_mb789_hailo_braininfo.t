use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Spec;

BEGIN { unshift @INC, "$Bin/../.." }

use Mediabot::Hailo::BrainInfo qw(brain_info save_existing hailo_command);

{
    package MB789::Brain;
    sub new { bless { stats => $_[1], saves => 0 }, $_[0] }
    sub stats { @{ $_[0]{stats} } }
    sub save { $_[0]{saves}++; return 1 }
}
{
    package MB789::Registry;
    sub new { bless { dir => $_[1], opens => [], brains => {} }, $_[0] }
    sub brain_path_for {
        my ($self, $channel) = @_;
        return File::Spec->catfile($self->{dir}, lc($channel) eq '#i/o' ? 'io.brn'
            : lc($channel) eq '#other' ? 'other.brn' : 'missing.brn');
    }
    sub brain_for {
        my ($self, $channel) = @_;
        push @{ $self->{opens} }, $channel;
        return $self->{brains}{lc $channel};
    }
}
{
    package MB789::Bot;
    sub new { bless { hailo_registry => $_[1] }, $_[0] }
    sub hailo_channel_policy {
        return { master => 1, learn => 1, respond => 0, chatter => 0 };
    }
}
{
    package MB789::Context;
    sub new { my ($class, %args) = @_; bless \%args, $class }
    sub require_level {
        my ($self, $level) = @_;
        return 1 if $level eq 'Master' && $self->{master};
        return 1 if $level eq 'Owner' && $self->{owner};
        push @{ $self->{replies} }, 'Access denied';
        return;
    }
    sub args { $_[0]{args} }
    sub bot { $_[0]{bot} }
    sub reply_private { push @{ $_[0]{replies} }, $_[1] }
}

my $dir = tempdir(CLEANUP => 1);
my $registry = MB789::Registry->new($dir);
my $policy = { master => 1, learn => 1, respond => 0, chatter => 0 };

my $absent = brain_info($registry, '#i/o', $policy);
ok($absent->{ok}, 'absent channel brain is reported');
like($absent->{text}, qr/\bstate=absent\z/, 'absent status is explicit');
is(scalar @{ $registry->{opens} }, 0, 'inspection does not seed an absent brain');

for my $name ('io.brn', 'other.brn') {
    open my $fh, '>:raw', File::Spec->catfile($dir, $name) or die $!;
    print {$fh} "fixture";
    close $fh;
}
$registry->{brains}{'#i/o'} = MB789::Brain->new([17, 9, 21, 22]);
$registry->{brains}{'#other'} = MB789::Brain->new([31, 14, 41, 42]);
my $info = brain_info($registry, '#i/o', $policy);
ok($info->{ok}, 'existing channel brain can be inspected');
like($info->{text}, qr/tokens=17 expressions=9 previous_links=21 next_links=22/,
    'Hailo counters are explicit and distinct from MegaHAL nodes');
unlike($info->{text}, qr/\.brn|nodes=/,
    'neither brain path nor MegaHAL node label is emitted');
my $other = brain_info($registry, '#other', $policy);
like($other->{text}, qr/tokens=31.*previous_links=41/, 'other channel remains distinct');

my $bot = MB789::Bot->new($registry);
my $ctx = MB789::Context->new(bot => $bot, master => 0,
    args => ['braininfo', '#i/o'], replies => []);
hailo_command($ctx);
like($ctx->{replies}[-1], qr/Access denied/, 'non-Master cannot read brain counters');
$ctx->{master} = 1;
$ctx->{args} = ['braininfo'];
hailo_command($ctx);
like($ctx->{replies}[-1], qr/Syntax: hailo braininfo <#channel>/,
    'explicit channel is required');
$ctx->{args} = ['braininfo', '#i/o'];
hailo_command($ctx);
my $visible = join(' ', @{ $ctx->{replies} });
$visible =~ s/\x03\d{0,2}(?:,\d{1,2})?//g;
$visible =~ s/[\x02\x0f\x1f]//g;
like($visible, qr/Hailo #i\/o.*17 jetons.*9 expressions/,
    'authorized caller gets private channel-specific counters');

$ctx->{args} = ['help'];
hailo_command($ctx);
like($ctx->{replies}[-1], qr/braininfo.*savebrain.*forgetword/,
    'operator can see available commands and the corpus limitation');
$ctx->{args} = ['savebrain', '#i/o'];
hailo_command($ctx);
is($registry->{brains}{'#i/o'}{saves}, 0, 'Master cannot save a brain');
$ctx->{owner} = 1;
hailo_command($ctx);
is($registry->{brains}{'#i/o'}{saves}, 1, 'Owner saved only the requested brain');
is($registry->{brains}{'#other'}{saves}, 0, 'other channel brain untouched');
my $missing = save_existing($registry, '#missing');
ok(!$missing->{ok}, 'save does not create an absent brain');
is_deeply($registry->{opens}, ['#i/o', '#other', '#i/o', '#i/o'],
    'absent save did not open or seed a channel');

my $link = File::Spec->catfile($dir, 'other.brn');
unlink $link or die $!;
symlink File::Spec->catfile($dir, 'io.brn'), $link or die $!;
my $unsafe = brain_info($registry, '#other', $policy);
ok(!$unsafe->{ok}, 'symlink brain is refused');
unlike($unsafe->{error}, qr/\.brn/, 'error does not disclose a path');

done_testing;
