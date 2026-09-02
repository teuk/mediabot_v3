# MB720-A — Hailo channel brain isolation and reply-before-learn foundation.

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;
use File::Temp qw(tempdir);
use Mediabot::Hailo::BrainRegistry;

{
    package MB720::Brain;
    sub new { bless { path => $_[1], events => $_[2], saves => 0 }, $_[0] }
    sub reply { push @{ $_[0]{events} }, 'reply'; return 'candidate' }
    sub learn { push @{ $_[0]{events} }, 'learn'; return 1 }
    sub save  { $_[0]{saves}++; return 1 }
}

sub _slurp_1019 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _write_seed_1019 {
    my ($path, $text) = @_;
    open my $fh, '>:raw', $path or die "cannot write $path: $!";
    print {$fh} $text;
    close $fh or die "cannot close $path: $!";
}

return sub {
    my ($assert) = @_;

    my $tmp = tempdir(CLEANUP => 1);
    my $root = File::Spec->catdir($tmp, 'brains');
    my $legacy = File::Spec->catfile($tmp, 'legacy.brn');
    _write_seed_1019($legacy, "legacy-seed\n");

    my %events;
    my $registry = Mediabot::Hailo::BrainRegistry->new(
        root         => $root,
        network      => 'ExampleNet',
        legacy_brain => $legacy,
        max_open     => 2,
        factory      => sub {
            my ($path, $channel, $key) = @_;
            return MB720::Brain->new($path, ($events{$key} ||= []));
        },
    );

    my $a = $registry->brain_for('#Alpha');
    my $a_folded = $registry->brain_for('#alpha');
    my $b = $registry->brain_for('#Beta');

    $assert->is($a_folded, $a,
        'RFC-casemapped variants share one channel brain');
    $assert->ok($a ne $b,
        'different channels receive different Hailo objects');

    my $path_a = $registry->brain_path_for('#Alpha');
    my $path_b = $registry->brain_path_for('#Beta');
    $assert->ok($path_a ne $path_b,
        'different channels receive different durable brain paths');
    $assert->like($path_a, qr/[0-9a-f]{64}[.]brn\z/,
        'brain filename is a traversal-safe opaque identifier');
    $assert->unlike($path_a, qr/Alpha/i,
        'raw channel name is absent from the brain filename');

    for my $path ($path_a, $path_b) {
        open my $fh, '<:raw', $path or die "cannot read seeded brain $path: $!";
        local $/;
        $assert->is(<$fh>, "legacy-seed\n",
            'legacy training is copied once into a new channel brain');
        close $fh;
    }

    my $odd_path = $registry->brain_path_for('#../escape');
    $assert->like($odd_path, qr/\Q$root\E\/[0-9a-f]{64}[.]brn\z/,
        'traversal-shaped but valid IRC text remains confined by hashing');

    my $limited_root = File::Spec->catdir($tmp, 'limited');
    my @made;
    my $limited = Mediabot::Hailo::BrainRegistry->new(
        root         => $limited_root,
        network      => 'ExampleNet',
        legacy_brain => $legacy,
        max_open     => 1,
        factory      => sub {
            my ($path) = @_;
            my $brain = MB720::Brain->new($path, []);
            push @made, $brain;
            return $brain;
        },
    );
    $limited->brain_for('#One');
    $limited->brain_for('#Two');
    $assert->is($made[0]{saves}, 1,
        'least-recently-used brain is saved before eviction');
    $assert->is($limited->stats->{open_brains}, 1,
        'open brain count stays within the configured bound');

    my $hailo = _slurp_1019(File::Spec->catfile('.', 'Mediabot', 'Hailo.pm'));
    my ($turn) = $hailo =~ /(sub hailo_reply_before_learning \{.*?)(?=\n# Clean up|\nsub is_hailo_excluded_nick)/s;
    $turn //= '';
    $assert->ok(index($turn, '->reply($text)') >= 0,
        'turn helper generates a Hailo candidate');
    $assert->ok(index($turn, '->learn($text)') > index($turn, '->reply($text)'),
        'triggering line is learned only after candidate generation');
    $assert->unlike($turn, qr/learn_reply/,
        'turn helper never reintroduces learn_reply ordering');

    my $main = _slurp_1019(File::Spec->catfile('.', 'mediabot.pl'));
    $assert->is(scalar(() = $main =~ /get_hailo_runtime\(\$where\)/g), 3,
        'all three public Hailo paths select the current channel brain');
    $assert->unlike($main, qr/->learn_reply\(\$what\)/,
        'public Hailo paths no longer learn before replying');

    my $sample = _slurp_1019(File::Spec->catfile('.', 'mediabot.sample.conf'));
    $assert->like($sample, qr/^HAILO_BRAIN_DIR=var\/hailo$/m,
        'sample configuration documents the private channel brain root');
    $assert->like($sample, qr/^HAILO_LEGACY_BRAIN=mediabot_v3[.]brn$/m,
        'sample configuration preserves legacy training as a seed');
};
