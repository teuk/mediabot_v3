#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/..";
use Getopt::Long qw(GetOptions);
use Mediabot::External::Reddit ();
binmode STDOUT, ':encoding(UTF-8)';
my ($url,$live,$help)=('',0,0);
GetOptions('url=s'=>\$url,'live'=>\$live,'help'=>\$help) or exit 2;
if ($help) {
    print "Usage: perl tools/reddit_preview_check.pl --url REDDIT_URL [--live]\n";
    print "Default: URL classification only, no network. --live: public Reddit metadata lookup, no database/configuration access and no IRC output.\n";
    exit 0;
}
my $info=Mediabot::External::Reddit::url_info($url);
die "[KO] Use a valid public HTTP(S) Reddit link.\n" unless $info;
print "Type: $info->{kind}\nCanonical: $info->{url}\n";
print "Activation: +Reddit on the chosen channel; independent of +UrlTitle.\n";
exit 0 unless $live;
my $raw=eval {Mediabot::External::Reddit::fetch($url)};
my $r=Mediabot::External::Reddit::_result($raw);
my $line=Mediabot::External::Reddit::render('preview',$info,$r);
print "State: $r->{state}\n";
print Mediabot::External::Reddit::_plain($line,2048),"\n" if defined($line);
print "[DONE] No configuration, database or IRC operation.\n";
exit($r->{state} eq 'ok'?0:1);
