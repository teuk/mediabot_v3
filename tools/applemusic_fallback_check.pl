#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/..";
use Getopt::Long qw(GetOptions);
use Mediabot::Conf;
use Mediabot::External ();
use Mediabot::External::AppleMusicFallback ();
binmode STDOUT, ':encoding(UTF-8)';
my ($file,$live,$url,$help)=('mediabot.conf',0,'',0);
GetOptions('conf=s'=>\$file,'live'=>\$live,'url=s'=>\$url,'help'=>\$help) or exit 2;
if ($help) {
    print "Usage: perl tools/applemusic_fallback_check.pl --conf mediabot.conf [--live --url APPLE_MUSIC_TRACK_URL]\n";
    print "Default: key presence only, no network. --live: iTunes track lookup, up to two basic Tavily searches, Spotify metadata and YouTube videos metadata; these services can consume quota. No IRC, database, config or memory writes.\n";
    exit 0;
}
die "[KO] --url requires --live.\n" if length($url) && !$live;
my @stat=stat($file);
die "[KO] Configuration must be a readable regular file with mode 0600.\n"
    unless @stat && -f $file && -r $file && ($stat[2]&0777)==0600;
my $conf=eval {Mediabot::Conf->new({},$file)};
die "[KO] Configuration cannot be parsed.\n" unless $conf;
{package MB929ProbeLog;sub log {1}}
my $bot={conf=>$conf,logger=>bless({},'MB929ProbeLog')};
my $ready=Mediabot::External::AppleMusicFallback::prerequisites($bot);
print 'Tavily search: ',($ready->{tavily}?'configured':'missing'),"\n";
print 'YouTube metadata: ',($ready->{youtube}?'configured':'missing'),"\n";
print "Activation: existing +AppleMusic and explicit +AppleMusicFallback on each chosen channel.\n";
exit($ready->{tavily} && $ready->{youtube}?0:1) unless $live;
die "[KO] Use an HTTPS music.apple.com track link (song ID or album link with ?i=TRACK_ID).\n"
    unless length($url)<=2048 && $url =~ m{\Ahttps://music\.apple\.com/[a-z]{2}/[^\x00-\x20\x7f]+\z}i;
my $info=Mediabot::External::AppleMusic::_applemusic_url_info($url);
die "[KO] No exact track ID in this link; albums and playlists are not matched.\n" unless $info->{track_id};
my $r=eval {
    my $http=Mediabot::External::_make_http(timeout=>6,verify_SSL=>1,max_size=>512*1024);
    my $m=Mediabot::External::AppleMusic::_applemusic_lookup_track($bot,$http,$info->{storefront},$info->{track_id});
    Mediabot::External::AppleMusicFallback::record($m,$info);
};
die "[KO] Exact Apple Music track metadata unavailable.\n" unless $r;
print "$r->{artist} — $r->{title} ($r->{seconds}s)\n";
my $missing=0;
for my $platform (qw(spotify youtube)) {
    my $urls=eval {Mediabot::External::AppleMusicFallback::fetch($bot,$r,$platform)};
    if (ref($urls) eq 'ARRAY' && @$urls==1) {print "[OK] $platform $urls->[0]\n"}
    else {print "[UNCONFIRMED] $platform: no verified match (metadata, access, quota or search may be unavailable).\n";$missing++}
}
print "[DONE] Nothing sent to IRC or written to the database/configuration.\n";
exit($missing?1:0);
