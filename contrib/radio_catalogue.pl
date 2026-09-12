#!/usr/bin/env perl
# MB734: private local adapter. The HTTP API never accepts SQL or user IDs.
use strict;
use warnings;
use Config::Simple;
use DBI;
use JSON::PP;
use File::Spec;
my $json = JSON::PP->new->canonical->utf8;
my $result = eval {
    die "config" unless @ARGV == 1 && -f $ARGV[0];
    my $conf = Config::Simple->new($ARGV[0]) or die "config";
    my %v = $conf->vars;
    my $name = $v{'mysql.MAIN_PROG_DDBNAME'} // '';
    my $host = $v{'mysql.MAIN_PROG_DBHOST'} // 'localhost';
    my $port = $v{'mysql.MAIN_PROG_DBPORT'} // 3306;
    die "db scope" unless $name =~ /\A[A-Za-z0-9_]{1,64}\z/
        && $host =~ /\A(?:localhost|127\.0\.0\.1|::1)\z/
        && $port =~ /\A\d{1,5}\z/ && $port > 0 && $port <= 65535;
    $host = '127.0.0.1' if $host eq 'localhost';
    my $input = '';
    while (read(STDIN, my $chunk, 4096)) { $input .= $chunk; die "input" if length($input) > 8192 }
    my $r = $json->decode($input);
    my $db = DBI->connect("DBI:MariaDB:database=$name;host=$host;port=$port;mariadb_connect_timeout=5;mariadb_read_timeout=10;mariadb_write_timeout=10",
        $v{'mysql.MAIN_PROG_DBUSER'}, $v{'mysql.MAIN_PROG_DBPASS'},
        { RaiseError => 1, PrintError => 0, AutoCommit => 1 }) or die "connection";
    $db->do('SET NAMES utf8mb4');
    my $action = $r->{action} // '';
    my $out;
    if ($action eq 'preflight') {
        my $owners = $db->selectall_arrayref(q{SELECT DISTINCT m.id_user,u.nickname FROM MP3 m
            JOIN USER u ON u.id_user=m.id_user ORDER BY m.id_user}, {Slice=>{}});
        my $roots = $db->selectcol_arrayref('SELECT DISTINCT folder FROM MP3 ORDER BY folder');
        my $owner_valid = ($r->{owner}//'') =~ /\A[1-9]\d*\z/
            ? ($db->selectrow_array('SELECT id_user FROM USER WHERE id_user=?',undef,$r->{owner}) // 0) : 0;
        $out = {owners=>$owners, roots=>$roots, owner_valid=>$owner_valid, config=>{map {$_=>($v{"radio.$_"}//'')}
            qw(YTDLP_PATH YTDLP_COOKIES_FILE YTDLP_REMOTE_COMPONENTS YOUTUBEDL_INCOMING
               LIQUIDSOAP_TELNET_HOST LIQUIDSOAP_TELNET_PORT LIQUIDSOAP_QUEUE_ID RADIO_DOWNLOAD_GROUP_READ)}};
    } elsif ($action eq 'youtube') {
        die "video" unless ($r->{youtube}//'') =~ /\A[A-Za-z0-9_-]{11}\z/;
        $out = {tracks=>$db->selectall_arrayref('SELECT * FROM MP3 WHERE id_youtube=? ORDER BY id_mp3 LIMIT 50',
                                              {Slice=>{}}, $r->{youtube})};
    } elsif ($action eq 'search') {
        my $q = $r->{query} // '';
        die "query" unless length($q) && length($q)<=255 && $q !~ /[\x00-\x1f]/;
        # Treat % and _ as literal input, not caller-selected wildcards.
        (my $like=$q) =~ s/([!%_])/!$1/g;
        $like = '%'.$like.'%';
        $out = {tracks=>$db->selectall_arrayref(q{
            SELECT * FROM MP3 WHERE artist LIKE ? ESCAPE '!' OR title LIKE ? ESCAPE '!'
            ORDER BY CASE WHEN artist=? THEN 0 WHEN artist LIKE ? ESCAPE '!' THEN 1 ELSE 2 END,
                     RAND() LIMIT 200}, {Slice=>{}}, $like, $like, $q, $like)};
    } elsif ($action eq 'register') {
        die "owner" unless ($r->{owner}//'') =~ /\A[1-9]\d*\z/;
        die "video" unless ($r->{youtube}//'') =~ /\A[A-Za-z0-9_-]{11}\z/;
        for (qw(folder filename artist title)) {
            die "metadata" unless defined($r->{$_}) && !ref($r->{$_}) && length($r->{$_})<=255
                && $r->{$_} !~ /[\x00-\x1f]/;
        }
        die "filename" unless $r->{filename} eq $r->{youtube}.'.mp3' && File::Spec->file_name_is_absolute($r->{folder});
        $db->begin_work;
        die "owner missing" unless $db->selectrow_array('SELECT id_user FROM USER WHERE id_user=?', undef, $r->{owner});
        # Keep existing cached ownership; never use a remote bot's local numeric UID.
        my $track = $db->selectrow_hashref('SELECT * FROM MP3 WHERE id_youtube=? AND folder=? AND filename=? LIMIT 1 FOR UPDATE',
            undef, @{$r}{qw(youtube folder filename)});
        unless ($track) {
            $db->do('INSERT INTO MP3 (id_user,id_youtube,folder,filename,artist,title) VALUES (?,?,?,?,?,?)',
                undef, @{$r}{qw(owner youtube folder filename artist title)});
            my $id = $db->last_insert_id(undef,undef,'MP3','id_mp3');
            $track = $db->selectrow_hashref('SELECT * FROM MP3 WHERE id_mp3=?',undef,$id);
        }
        die "insert" unless $track && $track->{id_mp3};
        $db->commit;
        $out = {track=>$track};
    } else { die "action" }
    $db->disconnect;
    +{ok=>JSON::PP::true, %$out};
};
print $json->encode($result || {ok=>JSON::PP::false,code=>'catalogue_failed'}), "\n";
exit($result ? 0 : 1);
