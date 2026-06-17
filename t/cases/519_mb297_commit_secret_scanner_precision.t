#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

my $root = File::Spec->rel2abs("$Bin/../..");
my $commit = File::Spec->catfile($root, 'commit.sh');
my $sample = File::Spec->catfile($root, 'mediabot.sample.conf');

open my $cfh, '<', $commit or die "$commit: $!";
local $/;
my $source = <$cfh>;
close $cfh;

like($source, qr/mb297-B1: keep the staged-secret scanner precise/, 'commit.sh contains MB297 marker');
like($source, qr/credential_key_re\s*=\s*re\.compile/, 'scanner has dedicated credential-key matcher');
like($source, qr/Match credential \*key endings\*/, 'scanner documents exact key-ending behavior');
unlike($source, qr/\(\?:pass\(\?:word\)\?\|dbpass\|adminpass\|api_\?key\|apikey\|token\|secret\|/, 'old broad substring matcher is gone');

my ($scanner) = $source =~ m{python3 - "\$tmp" "\$p" <<'PY'\n(.*?)\nPY\n}s;
ok(defined($scanner) && length($scanner), 'embedded Python scanner extracted from commit.sh');

my $tmp = tempdir(CLEANUP => 1);
my $scanner_py = File::Spec->catfile($tmp, 'scanner.py');
open my $sfh, '>', $scanner_py or die "$scanner_py: $!";
print {$sfh} $scanner;
close $sfh;

sub run_scanner {
    my ($path, $logical_path) = @_;
    $logical_path = $path unless defined $logical_path;
    my $quoted_scanner = $scanner_py;
    my $quoted_path = $path;
    my $quoted_logical = $logical_path;
    $quoted_scanner =~ s/'/'"'"'/g;
    $quoted_path =~ s/'/'"'"'/g;
    $quoted_logical =~ s/'/'"'"'/g;
    my $output = qx{python3 '$quoted_scanner' '$quoted_path' '$quoted_logical' 2>&1};
    return ($? >> 8, $output);
}

my ($sample_rc, $sample_out) = run_scanner($sample);
is($sample_rc, 1, 'real mediabot.sample.conf is clean');
is($sample_out, '', 'clean sample emits no diagnostic');

for my $rel (
    'Mediabot/Mediabot.pm',
    'Mediabot/Partyline.pm',
    'commit.sh',
) {
    my $file = File::Spec->catfile($root, split m{/}, $rel);
    my ($rc, $out) = run_scanner($file, $rel);
    is($rc, 1, "$rel is not a false positive");
    is($out, '', "$rel emits no false diagnostic");
}

my ($fixture_rc, $fixture_out) = run_scanner(
    File::Spec->catfile($root, 't', 'cases', '519_mb297_commit_secret_scanner_precision.t'),
    't/cases/519_mb297_commit_secret_scanner_precision.t',
);
is($fixture_rc, 1, 'intentional scanner regression fixtures are exempt by exact path');
is($fixture_out, '', 'fixture exemption emits no diagnostic');

my $safe = File::Spec->catfile($tmp, 'safe.conf');
open my $safe_fh, '>', $safe or die "$safe: $!";
print {$safe_fh} <<'SAFE';
MAX_TOKENS=400
TOKEN_TTL=3600
PASSWORD_COLUMNS=password
AUTH_TOKEN_TTL=120
API_KEY=
DBPASS=<YOUR_DB_PASSWORD>
SESSION_SECRET=CHANGE_ME_WITH_A_LONG_RANDOM_SECRET
SAFE
close $safe_fh;
my ($safe_rc, $safe_out) = run_scanner($safe);
is($safe_rc, 1, 'non-secret token/password metadata and placeholders remain allowed');
is($safe_out, '', 'safe fixture emits no diagnostic');

my @bad = (
    [ 'api_key.conf', "API_KEY=real-secret-value-123456789\n" ],
    [ 'dbpass.conf', "MAIN_PROG_DBPASS=correct-horse-battery-staple\n" ],
    [ 'auth_token.conf', "AUTH_TOKEN=token-value-that-is-not-a-placeholder\n" ],
    [ 'private_key.txt', "-----BEGIN PRIVATE KEY-----\nnot-a-real-key\n" ],
    [ 'openai.txt', "OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz1234567890\n" ],
);

for my $case (@bad) {
    my ($name, $body) = @{$case};
    my $file = File::Spec->catfile($tmp, $name);
    open my $fh, '>', $file or die "$file: $!";
    print {$fh} $body;
    close $fh;
    my ($rc, $out) = run_scanner($file);
    is($rc, 0, "$name is detected");
    like($out, qr/\S/, "$name returns a bounded reason");
    unlike($out, qr/correct-horse|token-value|abcdefghijklmnopqrstuvwxyz/, "$name does not echo the secret value");
}

done_testing();
