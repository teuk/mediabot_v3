#!/usr/bin/env perl
# MB805: exercise the rebuild protocol on synthetic data only. No live brain,
# channel, configuration or saved conversation is read or changed.
use strict;
use warnings;
use File::Copy qw(copy);
use File::Spec;
use File::Temp qw(tempdir);
use Digest::SHA qw(sha256_hex);

die "Usage: perl tools/mb_hailo_forget_rehearsal.pl\n" if @ARGV;
eval { require Hailo; 1 } or die "[KO] Hailo is unavailable.\n";

my $dir = tempdir('mb805-hailo-XXXXXX', DIR => '/home/mediabot', CLEANUP => 1);
chmod 0700, $dir or die "[KO] Cannot protect rehearsal directory.\n";
my $path = sub { File::Spec->catfile($dir, "$_[0].brn") };

sub _stats {
    my ($file) = @_;
    my $brain = eval { Hailo->new(brain => $file, save_on_exit => 0) };
    die "[KO] Synthetic brain could not be reopened.\n" if $@ || !$brain;
    my @stats = eval { $brain->stats };
    die "[KO] Synthetic brain statistics unavailable.\n"
        if $@ || @stats != 4 || grep { !defined($_) || $_ !~ /\A\d+\z/ } @stats;
    undef $brain;
    return join ',', @stats;
}

sub _train {
    my ($file, $lines) = @_;
    die "[KO] Synthetic training target already exists.\n" if -e $file || -l $file;
    my $brain = eval { Hailo->new(brain => $file, save_on_exit => 0) };
    die "[KO] Synthetic brain could not be created.\n" if $@ || !$brain;
    my $ok = eval {
        $brain->learn($_) for @$lines;
        $brain->save;
        1;
    };
    die "[KO] Synthetic brain could not be trained.\n" unless $ok;
    undef $brain;
    die "[KO] Synthetic brain file is missing.\n" unless -f $file && !-l $file;
    chmod 0600, $file or die "[KO] Cannot protect synthetic brain.\n";
    return _stats($file);
}

sub _digest {
    my ($file) = @_;
    open my $fh, '<:raw', $file or die "[KO] Synthetic file unavailable.\n";
    local $/;
    my $content = <$fh>;
    close $fh;
    return sha256_hex($content // '');
}

my @corpus = (
    'amber owl watches the station',
    'blue heron visits the station',
    'brown owlet guards the garden',
    'little owl circles the harbor',
);
my $original = $path->('original');
my $backup = $path->('backup');
my $other = $path->('other-channel');
my $baseline = _train($original, \@corpus);
_train($other, ['silver fox crosses the river']);
my $other_digest = _digest($other);
copy($original, $backup) or die "[KO] Synthetic backup failed.\n";
chmod 0600, $backup or die "[KO] Cannot protect synthetic backup.\n";
die "[KO] Synthetic backup differs.\n" unless _digest($original) eq _digest($backup);

my @phrase_keep = grep { $_ ne $corpus[0] } @corpus;
my @word_keep = grep { $_ !~ /\bowl\b/i } @corpus;
die "[KO] Synthetic selection is ambiguous.\n"
    unless @phrase_keep == 3 && @word_keep == 2
        && grep({ /\bowlet\b/ } @word_keep) == 1;
my $phrase_stats = _train($path->('without-phrase'), \@phrase_keep);
my $word_stats = _train($path->('without-word'), \@word_keep);
die "[KO] Synthetic rebuild did not change brain statistics.\n"
    if $phrase_stats eq $baseline || $word_stats eq $baseline;
die "[KO] Another synthetic channel changed.\n" unless _digest($other) eq $other_digest;

my $restored = $path->('restored');
copy($backup, $restored) or die "[KO] Synthetic restore failed.\n";
chmod 0600, $restored or die "[KO] Cannot protect synthetic restore.\n";
die "[KO] Synthetic restore differs.\n"
    unless _digest($restored) eq _digest($original) && _stats($restored) eq $baseline;

print '[OK] Synthetic Hailo 0.75: exact phrase=1 record; whole word=2 records; ',
    'isolated rebuild, reopen, other channel and restore verified.', "\n";
print '[LIMIT] This does not remove material from an existing channel brain. ',
    'A complete authorized training corpus is required.', "\n";
