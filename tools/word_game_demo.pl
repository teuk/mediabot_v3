#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use Getopt::Long qw(GetOptions);
my $check;
GetOptions('check'=>\$check) or die "Usage: $0 [--check]\n";
die "Unexpected arguments\n" if @ARGV;
require "$Bin/../plugins/longest-word-v3/lib/Engine.pm";
binmode STDOUT, ':encoding(UTF-8)';
my $engine=Mediabot::Plugin::LongestWord::Engine->new(rounds=>1,duration=>50,bonus=>3);
my @words=qw(ORIENTATES NOTAIRES RAISON SERA ETE);
$engine->begin_round(words=>\@words,letters=>'AEEINORSTT',now=>0);
print "Démo locale du moteur — dictionnaire réduit, sans MariaDB ni connexion IRC.\n";
print "<Mediabot> A E E I N O R S T T — maximum 10 lettres, 50 secondes au plus.\n";
my $closed;
my @guesses=(['Bob','RAISON',5],['Alice','NOTAIRES',8],['Bob','NOTAIRES',10],['Max','ORIENTATES',12]);
for my $g (@guesses) {
    my ($nick,$word,$at)=@$g;
    my $r=$engine->submit(id=>"n.$nick",nick=>$nick,word=>$word,now=>$at);
    print "<$nick> $word\n";
    if ($at==10) {
        die "Equal record accepted\n" unless ($r->{error}//'') eq 'not_longer';
        print "<Mediabot NOTICE> Non retenu : il faut au moins $r->{minimum} lettres.\n";
    }
    else {
        die "Demo proposal failed\n" unless $r->{ok};
        if (length($r->{word})==$engine->{longest}) {
            $closed=$engine->close_round($at);
            print "<Mediabot> $nick remporte la manche : 10 points + 3 de bonus = 13 points !\n";
        }
    }
}
die "Top did not close round immediately\n" unless $closed && $closed->{top_found} && $engine->{phase} eq 'done';
die "Old deadline scored round twice\n" if $engine->close_round(50);
print '<Mediabot> Top : '.join(', ',@{$closed->{solutions}}).".\n";
print '<Mediabot> '.join(' | ',map {$_->{nick}.' '.$_->{score}.' pts'} @{$engine->ranking}).".\n";
die "Unexpected accepted-word scores\n" unless join(',',map {$_->{score}} @{$engine->ranking}) eq '13,8,6';
print "[OK] Démo : record strict, refus des égalités, victoire immédiate au maximum et bonus compté une fois.\n" if $check;
