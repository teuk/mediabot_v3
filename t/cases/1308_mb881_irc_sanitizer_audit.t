use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use IPC::Open3;
use Symbol qw(gensym);

my @files = qw(Mediabot/Helpers.pm Mediabot/IRC/Sender.pm Mediabot/IRC/TextBudget.pm);
my %original;
for my $file (@files) {
    open my $fh, '<:raw', $file or die "$file: $!";
    $original{$file} = do {local $/; <$fh>};
}
my @cases = (['connected output owners', sub {}, 1]);
for my $name (qw(botPrivmsg botAction botNotice)) {
    push @cases, ["$name loses normalization", sub {
        my ($files) = @_;
        my ($body) = $files->{'Mediabot/IRC/Sender.pm'} =~ /(^sub \Q$name\E \{.*?^\})/ms;
        die "missing sender $name" unless defined $body;
        my $changed = $body;
        my $count = $changed =~ s/\$(sMsg|text) = _sanitize_irc_text\(\$\1\);/\$$1 = \$$1;/;
        die "missing sanitizer call $name" unless $count;
        $files->{'Mediabot/IRC/Sender.pm'} =~ s/\Q$body\E/$changed/;
    }, 0];
    push @cases, ["$name facade loses forwarding", sub {
        my ($files) = @_;
        $files->{'Mediabot/Helpers.pm'} =~ s/return Mediabot::IRC::Sender::\Q$name\E\(\@_\);/return;/
            or die "missing facade $name";
    }, 0];
}
for my $file (@files) {
    push @cases, ["missing $file", sub {delete $_[0]{$file}}, 0];
}
push @cases, ['normalizer loses NUL handling', sub {
    $_[0]{'Mediabot/IRC/TextBudget.pm'} =~ s/\\r\\n\\x00/\\r\\n/ or die 'missing NUL normalization';
}, 0];
push @cases, ['sender bridge loses forwarding', sub {
    $_[0]{'Mediabot/IRC/Sender.pm'} =~ s/return Mediabot::Helpers::_sanitize_irc_text\(\@_\);/return \$_[0];/
        or die 'missing sender bridge';
}, 0];
push @cases, ['Helpers bridge loses forwarding', sub {
    $_[0]{'Mediabot/Helpers.pm'} =~ s/return Mediabot::IRC::TextBudget::_sanitize_irc_text\(\@_\);/return \$_[0];/
        or die 'missing Helpers bridge';
}, 0];
for my $case (@cases) {
    my ($label, $mutate, $healthy) = @$case;
    my %files = %original;
    $mutate->(\%files);
    my $root = tempdir(CLEANUP => 1);
    for my $file (keys %files) {
        make_path(dirname("$root/$file"));
        open my $fh, '>:raw', "$root/$file" or die $!;
        print {$fh} $files{$file}; close $fh;
    }
    my $err = gensym;
    my $pid = open3(undef, my $out, $err, $^X, 'tools/security_audit.pl', '--root', $root);
    my $stdout = do {local $/; <$out>} // '';
    my $stderr = do {local $/; <$err>} // '';
    waitpid($pid, 0);
    if ($healthy) {
        like($stdout, qr/\[ok\].*IRC output sanitizer wiring covers all three/, "$label: relevant invariant passes");
        unlike($stdout, qr/\[FAIL\].*IRC output sanitizer wiring/, "$label: no false rejection at this boundary");
    }
    else {
        like($stdout, qr/\[FAIL\].*IRC output sanitizer wiring or implementation is incomplete/,
            "$label: actual audit detects the disconnected owner");
        isnt($?, 0, "$label: audit cannot report GO");
    }
}
# The partial trees intentionally omit the other audit owners. Only the IRC
# invariant is assessed; no claim is made that the full fixture audit is green.
done_testing;
