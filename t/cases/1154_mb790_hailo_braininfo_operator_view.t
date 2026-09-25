use strict;
use warnings;
use utf8;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Spec;

BEGIN { unshift @INC, "$Bin/../.." }

use Mediabot::Hailo::BrainInfo qw(brain_info brain_report hailo_command);
use Mediabot::Hailo::Policy;

{
    package MB790::Brain;
    sub stats { (9020, 29147, 38631, 39712) }
}
{
    package MB790::Registry;
    sub new { bless { path => $_[1], opens => 0 }, $_[0] }
    sub brain_path_for { $_[0]{path} }
    sub brain_for { $_[0]{opens}++; bless {}, 'MB790::Brain' }
}
{
    package MB790::Bot;
    sub new { bless { hailo_registry => $_[1], hailo_policy => $_[2], ratio => 23 }, $_[0] }
    sub hailo_channel_policy { { master => 1, learn => 1, respond => 1, chatter => 1 } }
    sub get_hailo_channel_ratio { $_[0]{ratio} }
}
{
    package MB790::Context;
    sub new { bless { bot => $_[1], replies => [], args => ['braininfo', '#radiocapsule'] }, $_[0] }
    sub require_level { 1 }
    sub args { $_[0]{args} }
    sub bot { $_[0]{bot} }
    sub reply_private { push @{ $_[0]{replies} }, $_[1] }
}

my $dir = tempdir(CLEANUP => 1);
my $path = File::Spec->catfile($dir, 'radiocapsule.brn');
my $registry = MB790::Registry->new($path);
my $runtime = Mediabot::Hailo::Policy->new(
    min_words => 3, max_words => 20, key_reply_rate => 95,
);
my $bot = MB790::Bot->new($registry, $runtime);
my $ctx = MB790::Context->new($bot);

ok(hailo_command($ctx), 'absent brain is displayed without opening it');
is($registry->{opens}, 0, 'absent brain was not seeded');
is(scalar @{ $ctx->{replies} }, 3, 'absent brain and effective policy use three notices');
like($ctx->{replies}[0], qr/aucun cerveau enregistré/, 'absence is explained');
like($ctx->{replies}[1], qr/apprentissage actif \(phrases de 3 à 20 mots\)/,
    'effective learning bounds are visible');
like($ctx->{replies}[1], qr/réponses aux mentions actives \(95% avant les limites/,
    'effective addressed-reply rate is qualified');
like($ctx->{replies}[2], qr/23% de base, réduit selon l'activité/,
    'adaptive chatter base is qualified');

open my $fh, '>:raw', $path or die $!;
print {$fh} 'brain';
close $fh;
$ctx->{replies} = [];
ok(hailo_command($ctx), 'existing brain reports conversational view');
is(scalar @{ $ctx->{replies} }, 4, 'ready brain uses four bounded notices');
like($ctx->{replies}[0], qr/Hailo #radiocapsule : cerveau prêt \(SQLite, 5 octets\)/,
    'format reports disk size without claiming RAM usage');
like($ctx->{replies}[1], qr/9 020 jetons et 29 147 expressions.*38 631 liens.*39 712/,
    'readable numbers preserve Hailo counters');
like($ctx->{replies}[1], qr/Ce ne sont pas des phrases archivées/,
    'operators cannot mistake lossy expressions for a corpus');
ok(!grep(/radiocapsule\.brn|\bn[œo]uds\b/, @{ $ctx->{replies} }),
    'no path or MegaHAL node claim');
ok(!grep(length($_) > 300, @{ $ctx->{replies} }), 'four notices stay short');

my $info = brain_info($registry, '#radiocapsule', $bot->hailo_channel_policy);
like($info->{text}, qr/tokens=9020 expressions=29147 previous_links=38631 next_links=39712/,
    'existing machine-readable hailo_status contract is kept');
my $disabled = brain_report('#radiocapsule', $info,
    { master => 0, learn => 1, respond => 1, chatter => 1 },
    $runtime->operator_settings, 23);
is(scalar @$disabled, 3, 'disabled master switch suppresses misleading active settings');
like($disabled->[-1], qr/ni apprentissage ni réponse/, 'master switch is explicit');
my $off = brain_report('#radiocapsule', $info,
    { master => 1, learn => 0, respond => 0, chatter => 1 }, {}, -1);
like(join(' ', @$off), qr/apprentissage désactivé.*réponses aux mentions désactivées.*Libre expression : inactive \(ratio non configuré/,
    'disabled switches and missing ratio do not invent rates');
my $ratio_zero = brain_report('#radiocapsule', $info,
    { master => 1, learn => 0, respond => 0, chatter => 1 }, {}, 0);
like($ratio_zero->[-1], qr/inactive \(ratio de 0%\)/, 'zero chatter is silent despite enabled switch');
my $ratio_full = brain_report('#radiocapsule', $info,
    { master => 1, learn => 0, respond => 1, chatter => 1 },
    { key_reply_rate => 100 }, 100);
like(join(' ', @$ratio_full), qr/100% avant les limites.*100% de base/,
    'upper bound percentages are rendered');
my $unbounded = Mediabot::Hailo::Policy->new(max_words => 0)->operator_settings;
my $open_range = brain_report('#radiocapsule', $info,
    { master => 1, learn => 1, respond => 0, chatter => 0 }, $unbounded, undef);
like(join(' ', @$open_range), qr/phrases de 3 mots ou plus/, 'unbounded learning is described correctly');

done_testing;
