#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/..";
use Getopt::Long qw(GetOptions);
use Mediabot::Conf;
use Mediabot::Plugin::DictionaryV3;
use Mediabot::Plugin::WordSolverV3;

my ($conf, $letters) = ('mediabot.conf', 'AEEINORSTT');
GetOptions('conf=s' => \$conf, 'letters=s' => \$letters)
    or die "Usage: $0 [--conf mediabot.conf] [--letters AEEINORSTT]\n";
die "Unexpected arguments\n" if @ARGV;
my $result = eval {
    local $SIG{ALRM} = sub { die "dictionary_check_timeout\n" };
    alarm 20;
    die "dictionary_configuration\n" unless -f $conf && !-l $conf;
    my $configuration = Mediabot::Conf->new(undef, $conf) or die "dictionary_configuration\n";
    my $settings = Mediabot::Plugin::DictionaryV3->settings($configuration);
    my $dbh = Mediabot::Plugin::DictionaryV3->connect($settings);
    my $indexes = $dbh->selectall_arrayref('SHOW INDEX FROM `DICT`', { Slice => {} });
    die "dictionary_index_missing\n" unless grep {
        ($_->{Key_name} // '') eq 'sorted' && ($_->{Column_name} // '') eq 'sorted'
            && ($_->{Seq_in_index} // 0) == 1
    } @$indexes;
    my $solved = Mediabot::Plugin::WordSolverV3->solve($dbh, $letters);
    $dbh->disconnect;
    alarm 0;
    $solved;
};
unless ($result) {
    alarm 0;
    my ($code) = ($@ // '') =~ /\A(dictionary_[a-z_]+)/;
    $code //= 'dictionary_query';
    print STDERR "[KO] $code. Voir docs/LONGEST_WORD_PLUGIN.md pour la configuration privée et les droits SELECT.\n";
    exit 1;
}
my @top = grep { length($_) == $result->{longest} } @{ $result->{words} };
splice @top, 5 if @top > 5;
print '[OK] DICT.DICT, index sorted et lecture seule vérifiés : '
    . scalar(@{ $result->{words} }) . ' mots possibles ; maximum '
    . $result->{longest} . ' lettres : ' . join(', ', @top) . ".\n";
print "[OK] Aucun import, aucune écriture de données, aucun service redémarré.\n";
