package MB875FortniteFixture;
use strict;
use warnings;
use Exporter 'import';
use DBI;
use JSON::PP ();
use Mediabot::Context;
use Mediabot::Mediabot;
our @EXPORT_OK = qw(run_fortnite healthy_fortnite);

{ package MB875FortniteFixture::Conf;
  sub get { $_[1] eq 'fortnite.API_KEY' ? 'OFFLINE_FIXTURE_ONLY' : undef } }
{ package MB875FortniteFixture::Log;
  sub log { push @{$_[0]{lines}}, $_[2]; 1 } }
{ package MB875FortniteFixture::User;
  sub is_authenticated { $_[0]{auth} }
  sub has_level { $_[0]{allowed} && $_[1] eq 'User' }
  sub nickname { 'Reader' } sub level_description { 'Fixture' } }
{ package MB875FortniteFixture::Message; sub prefix { 'Reader!fixture@example.test' } }
{ package MB875FortniteFixture::IRC; sub nick_folded { 'FixtureBot' } }
{ package MB875FortniteFixture::HTTP;
  sub get {
      my ($self, $url, $options) = @_;
      push @{$self->{calls}}, [$url, $options];
      die 'unexpected offline Fortnite destination'
          unless $url eq 'https://fortnite-api.com/v2/stats/br/v2/fixture-account';
      return $self->{response};
  } }

sub healthy_fortnite {
    return {status => 200, data => {account => {name => 'Player'},
        battlePass => {level => 42, progress => 75}, stats => {all => {overall => {
            matches => 120, wins => 10, winRate => 8.333333, kills => 345,
            kd => 3.14159265, top3 => 12, top5 => 23, top10 => 34,
        }}}}};
}

sub run_fortnite {
    my ($body, %args) = @_;
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
    $dbh->do('CREATE TABLE USER (id_user INTEGER, nickname TEXT, fortniteid TEXT)');
    $dbh->do('INSERT INTO USER VALUES (?, ?, ?)', undef, 1, 'Target', 'fixture-account');
    my $bot = {dbh => $dbh, conf => bless({}, 'MB875FortniteFixture::Conf'),
        logger => bless({lines => []}, 'MB875FortniteFixture::Log'),
        irc => bless({}, 'MB875FortniteFixture::IRC'), out => [], notices => [], audit => [], console => []};
    my $http = bless({calls => [], response => $args{response} // {
        success => 1, status => 200, content => JSON::PP::encode_json($body),
    }}, 'MB875FortniteFixture::HTTP');
    my $ctx = Mediabot::Context->new(bot => $bot, nick => 'Reader',
        channel => exists($args{channel}) ? $args{channel} : '#test', command => 'f',
        args => exists($args{args}) ? $args{args} : ['Target'],
        message => bless({}, 'MB875FortniteFixture::Message'));
    $ctx->{user} = bless({auth => $args{unauthenticated} ? 0 : 1,
        allowed => $args{denied_level} ? 0 : 1}, 'MB875FortniteFixture::User');
    $ctx->{_user_fetched} = 1;
    my (@options, @warnings, $result, $ok, $error);
    {
        no warnings qw(redefine once);
        local *Mediabot::External::_make_http = sub { push @options, {@_}; $http };
        local *Mediabot::Helpers::botPrivmsg = sub { push @{$_[0]{out}}, [$_[1], $_[2]]; 1 };
        local *Mediabot::Helpers::botNotice = sub { push @{$_[0]{notices}}, [$_[1], $_[2]]; 1 };
        local *Mediabot::Helpers::noticeConsoleChan = sub { push @{$_[0]{console}}, $_[1]; 1 };
        local *Mediabot::Helpers::logBot = sub { push @{$_[0]{audit}}, [@_[2 .. $#_]]; 1 };
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my %handlers = Mediabot::_builtin_public_command_handlers();
        $ok = eval { $result = $handlers{f}->($ctx); 1 };
        $error = $@;
    }
    $dbh->disconnect;
    return {ok => $ok, error => $error, result => $result, bot => $bot,
        calls => $http->{calls}, options => \@options, warnings => \@warnings};
}
1;
