# t/cases/391_mb132_privmsg_redact_and_ignore_private.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

sub _redact_for_test {
    require Mediabot::IRC::Text;
    return Mediabot::IRC::Text::redact_service_secret(@_);
}

my $case = sub {
    my ($assert) = @_;

    my @cases = (
        ['identify secret',              'identify ****'],
        ['identify teuk secret',         'identify teuk ****'],
        ['IDENTIFY Teuk Secret',         'IDENTIFY Teuk ****'],
        ['id secret',                    'id ****'],
        ['id teuk secret',               'id teuk ****'],
        ['login user secret',            'login user ****'],
        ['auth user secret',             'auth user ****'],
        ['ghost nick secret',            'ghost nick ****'],
        ['recover nick secret',          'recover nick ****'],
        ['release nick secret',          'release nick ****'],
        ['register secret user@mail',    'register **** user@mail'],
        ['set password secret',          'set password ****'],
        ['hello identify secret',        'hello identify secret'],
    );

    for my $c (@cases) {
        my ($in, $want) = @$c;
        my $got = _redact_for_test($in);
        $assert->($got eq $want, "redact '$in' -> '$want'");
    }

    my $root = File::Spec->catdir($Bin, '..', '..');
    my $helpers_file = File::Spec->catfile($root, 'Mediabot', 'Helpers.pm');

    open my $hfh, '<', $helpers_file
        or do { $assert->(0, "cannot open Helpers.pm: $!"); return; };
    my $src = do { local $/; <$hfh> };
    close $hfh;

    my $sender_file = File::Spec->catfile($root, 'Mediabot', 'IRC', 'Sender.pm');
    open my $sfh, '<', $sender_file or die $!;
    my $sender_src = do {local $/; <$sfh>};

    $assert->($sender_src =~ /my \$log_msg = _redact_irc_service_secret_for_log\(\$sMsg\);/,
        'botPrivmsg redacts private service credentials before logging');
    my $text_file = File::Spec->catfile($root, 'Mediabot', 'IRC', 'Text.pm');
    open my $tfh, '<', $text_file or die $!;
    my $text_src = do {local $/; <$tfh>};
    $assert->($text_src =~ /\$verb eq 'identify' \|\| \$verb eq 'id'/,
        'identify and id are handled explicitly');
    $assert->($text_src =~ /\$parts\[-1\] = '\*\*\*\*'/,
        'identify 3-token form redacts last argument');

    $assert->($src =~ /mb132-B6: channel-scoped ignores/,
        'isIgnored contains mb132-B6 private/non-channel guard');
    $assert->($src =~ /return 0 unless defined\(\$sChannel\) && \$sChannel =~ \/\^\[#&!\+\]\//,
        'isIgnored returns before channel SQL for non-channel targets');
    $assert->($src =~ /my \$chan_label = \(defined\(\$sChannel\) && \$sChannel =~ \/\^\[#&!\+\]\//,
        'global ignore log path avoids substr undef warning');
};

if (caller) { return $case; }

my $tests = 0;
my $fail  = 0;
my $assert = sub {
    my ($ok, $name) = @_;
    $tests++;
    $name = 'unnamed assertion' unless defined $name && $name ne '';
    if ($ok) { print "ok $tests - $name\n"; }
    else { print "not ok $tests - $name\n"; $fail++; }
};

$case->($assert);
print "1..$tests\n";
exit($fail ? 1 : 0);
